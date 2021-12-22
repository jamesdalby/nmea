/// Process NMEA messages
library nmea;

import 'dart:async';
import 'dart:io';
import 'dart:convert';

// Everything starts with ESR's magnum opus: http://www.catb.org/gpsd/NMEA.html
// I am standing on the shoulders of giants.

/// Representation of a position, dated
class Pos {
  final double? lat, lng;
  final DateTime? utc;

  const Pos(this.lat, this.lng, this.utc);
  @override String toString() => "(${lat??'?'}, ${lng??'?'}) "+(utc?.toString()??'');
}

// parse and enqueue a message
void _parseNMEA(final String data, final EventSink<NMEA> sink) {
  final NMEA? ret = _sentence(data);
  if (ret != null) sink.add(ret);
}

// mangle a test time as received from bus into DateTime
DateTime _utcFrom(final String s) {
  int ms = s.length > 7 ? int.parse(s.substring(7)) : 0;
  var dateTime = DateTime.now();
  return DateTime.utc(
      dateTime.year,
      dateTime.month,
      dateTime.day,
      int.tryParse(s.substring(0,2))??0,
      int.tryParse(s.substring(2,4))??0,
      int.tryParse(s.substring(4,6))??0,
      ms
  );
}

DateTime _utcFromDT(final String ds, final String ts) {
  int ms = ts.length > 7 ? (int.tryParse(ts.substring(7))??0) : 0;
  return DateTime.utc(
      int.parse(ds.substring(4,6))+2000,
      int.parse(ds.substring(2,4)),
      int.parse(ds.substring(0,2)),
      int.parse(ts.substring(0,2)),
      int.parse(ts.substring(2,4)),
      int.parse(ts.substring(4,6)),
      ms
  );
}

abstract class NMEAReader {
  void process(void handleNMEA(var sentence)) async {}
}

/// NMEA source
class NMEASocketReader implements NMEAReader {

  /// A reader that will connect to hostname and port
  NMEASocketReader(this._hostname, this._portNum);

  /// time between reconnection attempts: 2 seconds
  static const Duration sec2 = Duration(seconds: 2);

  String _hostname;
  int _portNum;

  /// Set a new hostname, which (if changed) will drop the current connection (if any) and reconnect
  set hostname(h) {
    bool close = _hostname != h;
    _hostname = h;
    if (close) {
      _socket.close();
    }
  }

  /// Set a new port number which (if changed) will drop the current connection (if any) and reconnect
  set port(p) {
    bool close = _portNum != p;
    _portNum = p;
    if (close) {
      _socket.close();
    }
  }

  /// Current hostname
  String get hostname => _hostname;

  /// Current port number
  int get port => _portNum;

  late Socket _socket;

  /// socket for connections.  Use this judiciously, i.e not at all!
  Socket get socket => _socket;

  /// Initiate a connection and process arriving messages using the given handler `handleNMEA`
  ///
  /// This method will attempt to connect repeatedly to the source, and reconnect if the connection is lost
  /// If the hostname/port are invalid, it'll continue to attempt to connect, to cope with things like changing network
  /// state.  There is a 2 second sleep before any reconnection attempt.
  void process(void handleNMEA(var sentence)) async
  {

    print("Attempting to connect $_hostname:$_portNum");
    try {
      _socket = await Socket.connect(_hostname, _portNum);
      print("Connected");

      utf8.decoder.bind(_socket)
          .transform(LineSplitter())
          .transform(StreamTransformer.fromHandlers(handleData: _parseNMEA))
          .listen(
          handleNMEA,
          onError: (err, stack) {
            print("Communication error: $err\n$stack");
          },
          onDone: () {
            print("Disconnected (Peer), attempt reconnect in 2 secs");
            Future.delayed(sec2, () => process(handleNMEA));
          }
      );
      return;
    } catch (err) {
      print("Connection failed, try again in 2 seconds $err");
    }

    Future.delayed(sec2, () => process(handleNMEA));
  }
}

/// A reader that can read from an NMEA dump file
/// 
/// It inserts artificial delays to roughly match the timings of the messages
/// based on utc within GGA messages.
class NMEADummy implements NMEAReader {
  Stream<String> _src;

  NMEADummy(this._src);

  NMEADummy.from(File file) : _src = utf8.decoder.bind(file.openRead());

  void process(void handleNMEA(var sentence)) async
  {
    _src
        .transform(LineSplitter())
        .transform(StreamTransformer.fromHandlers(handleData: _parseNMEA))
        .transform(StreamTransformer.fromHandlers(handleData: _maybeDelay))
        .listen(handleNMEA);
  }

  DateTime? _initTime;
  DateTime? _firstMsg;

  void _maybeDelay(NMEA nmea, final EventSink sink) async {
    if (_initTime == null) {
      _initTime = DateTime.now();
    }
    DateTime? t;
    if (nmea is GGA) {
      t = nmea.utc;
    } /* else if (nmea is RMC) {
      t = nmea.utc;
    } else if (nmea is ZDA) {
      t = nmea.utc;
    }*/
    if (_firstMsg == null) {
      _firstMsg = t;
    } else if (t != null) {
        int b = t.difference(_firstMsg!).inSeconds;
        int a = DateTime.now().difference(_initTime!).inSeconds;
        
        if (a<b) {
          sleep(Duration(seconds: b-a));
       }
    }
    sink.add(nmea);
  }
}

/// base class for NMEA messages
abstract class NMEA {
  final List<String> s;
  final String type;
  final String talkerID;
  final int checksum;

  NMEA(this.s) :
        type = s[0].substring(0, 1),
        talkerID = s[0].substring(1, 3),
        checksum = int.parse(s[s.length - 1], radix: 16);

  @override String toString() {
    return "$type $talkerID $checksum $s";
  }
}

/// AIS VDM
///
/// See also [AIS](http://github.io//jamesdalby/jamais) if you want decoded AIS
class VDbase extends NMEA {
  final int fragments;
  final int fragment;
  final String msgID;
  final String radioChannel;
  final String payload;

  VDbase(final List<String> args) :
        fragments = int.parse(args[1]),
        fragment = int.parse(args[2]),
        msgID = args[3],
        radioChannel = args[4],
        payload = args[5],
        super(args);
}

class VDO extends VDbase {
  VDO(final List<String> args) : super(args);
}

class VDM extends VDbase {
  VDM(final List<String> args) : super(args);
}

/// AAM - Waypoint Arrival Alarm
class AAM extends NMEA {
  AAM(final List<String> args) : super(args);
}

/// APB - Autopilot Sentence "B"
//        1 2 3   4 5 6 7 8   9 10   11  12|   14|
//        | | |   | | | | |   | |    |   | |   | |
// $--APB,A,A,x.x,a,N,A,A,x.x,a,c--c,x.x,a,x.x,a*hh<CR><LF>
// Field Number:
//
// 1. Status A = Data valid V = Loran-C Blink or SNR warning V = general warning flag or other navigation systems when a reliable fix is not available
// 2. Status V = Loran-C Cycle Lock warning flag A = OK or not used
// 3. Cross Track Error Magnitude
// 4. Direction to steer, L or R
// 5. Cross Track Units, N = Nautical Miles
// 6. Status A = Arrival Circle Entered
// 7. Status A = Perpendicular passed at waypoint
// 8. Bearing origin to destination
// 9. M = Magnetic, T = True
// 10. Destination Waypoint ID
// 11. Bearing, present position to Destination
// 12. M = Magnetic, T = True
// 13. Heading to steer to destination waypoint
// 14. M = Magnetic, T = True
// 15.  Checksum
//
// Example: $GPAPB,A,A,0.10,R,N,V,V,011,M,DEST,011,M,011,M*82
class APB extends NMEA {

  APB(final List<String> args) :
        super(args);
}

/// BOD - Bearing - Waypoint to Waypoint
///
/// 1   2 3   4 5    6    7
/// |   | |   | |    |    |
/// $--BOD,x.x,T,x.x,M,c--c,c--c*hh<CR><LF>
/// Field Number:
/// 1 Bearing Degrees, True
/// 2 T = True
/// 3 Bearing Degrees, Magnetic
/// 4 M = Magnetic
/// 5 Destination Waypoint
/// 6 origin Waypoint
/// 7 Checksum

class BOD extends NMEA {
  BOD(final List<String> args) : super(args);
}



/// BWC - Bearing & Distance to Waypoint - Great Circle
/*                                                       12
        1         2       3 4        5 6   7 8   9 10  11|    13 14
        |         |       | |        | |   | |   | |   | |    |   |
 $--BWC,hhmmss.ss,llll.ll,a,yyyyy.yy,a,x.x,T,x.x,M,x.x,N,c--c,m,*hh<CR><LF>
Field Number:

1 UTC Time or observation
2 Waypoint Latitude
3 N = North, S = South
4 Waypoint Longitude
5 E = East, W = West
6 Bearing, degrees True
7 T = True
8 Bearing, degrees Magnetic
9 M = Magnetic
10 Distance, Nautical Miles
11 N = Nautical Miles
12 Waypoint ID
13 FAA mode indicator (NMEA 2.3 and later, optional)
14 Checksum
 */
class BWC extends NMEA {
  final Pos wpt;
  final double bearingTrue, bearingMag;
  final double distance;
  final String waypointID;

  BWC(final List<String> args)
      : wpt = Pos(
            _degFrom(args[2], args[3]),
            _degFrom(args[4], args[5]),
            _utcFrom(args[1])),
        bearingTrue = double.parse(args[6]),
        bearingMag = double.parse(args[8]),
        distance = double.parse(args[10]),
        waypointID = args[12],
        super(args);
}

/// Exactly the same spec as [BWC]
class BWR extends NMEA {
  final Pos wpt;
  final double bearingTrue, bearingMag;
  final double distance;
  final String waypointID;

  BWR(final List<String> args)
      : wpt = Pos(
      _degFrom(args[2], args[3]),
      _degFrom(args[4], args[5]),
      _utcFrom(args[1])),
        bearingTrue = double.parse(args[6]),
        bearingMag = double.parse(args[8]),
        distance = double.parse(args[10]),
        waypointID = args[12],
        super(args);
}


/*
GGA - Global Positioning System Fix Data

Time, Position and fix related data for a GPS receiver.

                                                     11
       1         2       3 4        5 6 7  8   9  10 |  12 13  14   15
       |         |       | |        | | |  |   |   | |   | |   |    |
$--GGA,hhmmss.ss,llll.ll,a,yyyyy.yy,a,x,xx,x.x,x.x,M,x.x,M,x.x,xxxx*hh<CR><LF>

Field Number:

1   UTC of this position report
2   Latitude
3   N or S (North or South)
4   Longitude
5   E or W (East or West)
6   GPS Quality Indicator (non null)
*     0 - fix not available,
*     1 - GPS fix,
*     2 - Differential GPS fix (values above 2 are 2.3 features)
*     3 = PPS fix
*     4 = Real Time Kinematic
*     5 = Float RTK
*     6 = estimated (dead reckoning)
*     7 = Manual input mode
*     8 = Simulation mode
7   Number of satellites in use, 00 - 12
8   Horizontal Dilution of precision (meters)
9   Antenna Altitude above/below mean-sea-level (geoid) (in meters)
10  Units of antenna altitude, meters
11  Geoidal separation, the difference between the WGS-84 earth ellipsoid and mean-sea-level (geoid), "-" means mean-sea-level below ellipsoid
12  Units of geoidal separation, meters
13  Age of differential GPS data, time in seconds since last SC104 type 1 or 9 update, null field when DGPS is not used
14  Differential reference station ID, 0000-1023
15  Checksum
*/
class GGA extends NMEA implements Pos {
  final Pos pos;
  final int? qual;
  final int? numSats;
  final double? horizontalDilution;
  final double? antennaAltitude;
  final String antennaAltitudeUnits;
  final double? geoidalSeparation;
  final String geoidalSeparationUnits;
  final double? ageOfDifferentialGPS;
  final String differentialReferenceStation;

  GGA(final List<String> args) :
        pos = Pos(
            _degFrom(args[2], args[3]),
            _degFrom(args[4], args[5]),
            _utcFrom(args[1])
        ),
        qual = int.tryParse(args[6]),
        numSats = int.tryParse(args[7]),
        horizontalDilution = double.tryParse(args[8]),
        antennaAltitude = double.tryParse(args[9]),
        antennaAltitudeUnits = args[10],
        geoidalSeparation = double.tryParse(args[9]),
        geoidalSeparationUnits = args[10],
        ageOfDifferentialGPS = _d(args[11]),
        differentialReferenceStation = args[12],
        super(args);



  @override String toString() {
    return super.toString() + "\n => $pos";
  }

  // delegates
  @override double? get lat => pos.lat;
  @override double? get lng => pos.lng;
  @override DateTime? get utc => pos.utc;
}

double? _d(String s, [double? dflt]) {
  // if (s == null) { return dflt; }
  return double.tryParse(s)??dflt;
}

double? _degFrom(final String d, final String nsew) {
  if (d.length == 0 || nsew.length != 1) {
    return null;
  }
  double dd = double.parse(d);
  int deg = dd ~/ 100;
  double min = (dd - deg*100) / 60;
  if (nsew == "S" || nsew == "W") {
    return - (deg + min);
  }
  return deg + min;
}

/*
    GLL - Geographic Position - Latitude/Longitude

    This is one of the sentences commonly emitted by GPS units.

           1       2 3        4 5         6 7  8
           |       | |        | |         | |  |
    $--GLL,llll.ll,a,yyyyy.yy,a,hhmmss.ss,a,m,*hh<CR><LF>

    Field Number:

    1   Latitude
    2   N or S (North or South)
    3   Longitude
    4   E or W (East or West)
    5   UTC of this position
    6   Status A - Data Valid, V - Data Invalid
    7   FAA mode indicator (NMEA 2.3 and later)
    8   Checksum
 */
class GLL extends NMEA implements Pos {
  Pos _pos;

  bool _valid;
  bool get valid => _valid;

  String? _faaMode;
  String? get faaMode => _faaMode;

  GLL(final List<String> args) :
        _pos = Pos(
            _degFrom(args[1], args[2]),
            _degFrom(args[3], args[4]),
            _utcFrom(args[5])
        ),
        _valid = args[6] == "A",
        _faaMode = args.length > 7 ? args[7] : null,
        super(args);

  @override String toString() {
    return super.toString() + "\n => $_pos";
  }
  // delegates
  @override double? get lat => _pos.lat;
  @override double? get lng => _pos.lng;
  @override DateTime? get utc => _pos.utc;
}

// Loran C - obsolete
class GLC extends NMEA {
  GLC(final List<String> args) : super(args);
}

// active satellites, not implemented
class GSA extends NMEA {
  GSA(final List<String> args) : super(args);
}

// satellites in view, not implemented
class GSV extends NMEA {
  GSV(final List<String> args) : super(args);
}

/*
    RMB - Recommended Minimum Navigation Information

    To be sent by a navigation receiver when a destination waypoint is active.

                                                                14
           1 2   3 4    5    6       7 8        9 10  11  12  13|  15
           | |   | |    |    |       | |        | |   |   |   | |   |
    $--RMB,A,x.x,a,c--c,c--c,llll.ll,a,yyyyy.yy,a,x.x,x.x,x.x,A,m,*hh<CR><LF>

    Field Number:

    1   Status, A = Active, V = Invalid
    2   Cross Track error - nautical miles
    3   Direction to Steer, Left or Right
    4   Origin Waypoint ID
    5   Destination Waypoint ID
    6   Destination Waypoint Latitude
    7   N or S
    8   Destination Waypoint Longitude
    9   E or W
    10  Range to destination in nautical miles
    11  Bearing to destination in degrees True
    12  Destination closing velocity in knots
    13  Arrival Status, A = Arrival Circle Entered. V = not entered/passed
    14  FAA mode indicator (NMEA 2.3 and later)
    15  Checksum
*/
class RMB extends NMEA {
  final bool status;
  final double? crossTrackError;
  final String directionToSteer; // 'L' or 'R'
  final String originWaypointID;
  final String destinationWaypointID;
  final Pos destinationWaypoint;
  final double? rangeToDestination;
  final double? bearingToDestination; // deg, true
  final double? destinationClosingVelocity;
  final bool? arrivalCircleEntered;
  final String faaModeIndicator;

  RMB(final List<String> args) :
        status = args[1] == "V",
        crossTrackError = _d(args[2]),
        directionToSteer = args[3],
        originWaypointID = args[4],
        destinationWaypointID = args[5],
        destinationWaypoint = Pos(_degFrom(args[6], args[7]), _degFrom(args[8], args[9]), null),
        rangeToDestination = _d(args[10]),
        bearingToDestination = _d(args[11]),
        destinationClosingVelocity = _d(args[12]),
        arrivalCircleEntered = args[13] == 'A' ? true : args[13] == 'V' ? false : null,
        faaModeIndicator = args[14],
        super(args);
}

/// RMC - Recommended Minimum Navigation Information
/// This is one of the sentences commonly emitted by GPS units.

///                                                            12
///        1         2 3       4 5        6  7   8   9    10 11|
///        |         | |       | |        |  |   |   |    |  | |
/// $--RMC,hhmmss.ss,A,llll.ll,a,yyyyy.yy,a,x.x,x.x,xxxx,x.x,a,m
/// Field Number:
/// 1. UTC Time
/// 2. Status, V=Navigation receiver warning A=Valid
/// 3. Latitude
/// 4. N or S
/// 5. Longitude
/// 6. E or W
/// 7. Speed over ground, knots
/// 8. Track made good, degrees true
/// 9. Date, ddmmyy
/// 10. Magnetic Variation, degrees
/// 11. E or W
/// 12. FAA mode indicator (NMEA 2.3 and later)

class RMC extends NMEA {
  final DateTime utc;
  final bool status;
  final Pos position;
  final double? sog;
  final double? trackMadeGood;
  final String dddmmyy;
  final double? magneticVariation;
  final String faaModeIndicator;

  RMC(final List<String> args) :
        utc = _utcFromDT(args[9], args[1]),
        status = args[2] == 'V',
        position = Pos(_degFrom(args[3], args[4]), _degFrom(args[5], args[6]), _utcFrom(args[1])),
        sog = _d(args[7]),
        trackMadeGood = _d(args[8]),
        dddmmyy = args[9],
        magneticVariation = _degFrom(args[10], args[11]),
        faaModeIndicator = args[12],
        super(args);
}

/*
    VTG - Track made good and Ground speed

           1  2  3  4  5	6  7  8 9   10
           |  |  |  |  |	|  |  | |   |
    $--VTG,x.x,T,x.x,M,x.x,N,x.x,K,m,*hh<CR><LF>

    Field Number:

    1   Course over ground, degrees True
    2   T = True
    3   Course over ground, degrees Magnetic
    4   M = Magnetic
    5   Speed over ground, knots
    6   N = Knots
    7   Speed over ground, km/hr
    8   K = Kilometers Per Hour
    9   FAA mode indicator (NMEA 2.3 and later)
    10    Checksum

    Note: in some older versions of NMEA 0183, the sentence looks like this:

           1  2  3   4  5
           |  |  |   |  |
    $--VTG,x.x,x,x.x,x.x,*hh<CR><LF>

    Field Number:

    1   True course over ground (degrees) 000 to 359
    2   Magnetic course over ground 000 to 359
    3   Speed over ground (knots) 00.0 to 99.9
    4   Speed over ground (kilometers) 00.0 to 99.9
    5   Checksum

    The two forms can be distinguished by field 2, which will be the fixed text 'T' in the newer form. The new form appears to have been introduced with NMEA 3.01 in 2002.
 */
class VTG extends NMEA {
  final double? cogTrue, cogMagnetic, sog, sogkmh;
  final String? faaModeIndicator;

  factory VTG (final List<String> args) {
    return args[2] == 'T' ? VTG._new(args) : VTG._old(args);
  }

  VTG._new(final List<String> args) :
        cogTrue = _d(args[1]),
        cogMagnetic = _d(args[3]),
        sog = _d(args[5]),
        sogkmh = _d(args[7]),
        faaModeIndicator = args[9],
        super(args);

  VTG._old(final List<String> args) :
        cogTrue = _d(args[1]),
        cogMagnetic = _d(args[2]),
        sog = _d(args[3]),
        sogkmh = _d(args[4]),
        faaModeIndicator = null,
        super(args);

}

/*
    XTE - Cross-Track Error, Measured

           1 2 3   4 5 6   7
           | | |   | | |   |
    $--XTE,A,A,x.x,a,N,m,*hh<CR><LF>

    Field Number:

    1   Status
        *  A - Valid
        *  V = Loran-C Blink or SNR warning
        *  V = general warning flag or other navigation systems when a reliable fix is not available
    2   Status
        * V = Loran-C Cycle Lock warning flag
        * A = Valid
    3   Cross Track Error Magnitude
    4   Direction to steer, L or R
    5   Cross Track Units, N = Nautical Miles
    6   FAA mode indicator (NMEA 2.3 and later, optional)
    7   Checksum
 */
class XTE extends NMEA {
  final List<String> status;
  final double? crossTrackError;
  final String directionToSteer;

  XTE(final List<String> args) :
        status = [ args[1], args[2] ],
        crossTrackError = _d(args[3]),
        directionToSteer = args[4],
        super(args);
}

/// ZDA - Time & Date - UTC, day, month, year and local time zone
/// This is one of the sentences commonly emitted by GPS units.
///
///	       1         2  3  4    5  6  7
///        |         |  |  |    |  |  |
/// $--ZDA,hhmmss.ss,xx,xx,xxxx,xx,xx*hh<CR><LF>
/// Field Number:
///
/// 1. UTC time (hours, minutes, seconds, may have fractional subsecond)
/// 2. Day, 01 to 31
/// 3. Month, 01 to 12
/// 4. Year (4 digits)
/// 5. Local zone description, 00 to +- 13 hours
/// 6. Local zone minutes description, 00 to 59, apply same sign as local hours
/// 7. Checksum
///
/// Example: $GPZDA,160012.71,11,03,2004,-1,00*7D
class ZDA extends NMEA {
  final DateTime utc;

  ZDA(final List<String> args)
      : utc = DateTime(
      int.parse(args[4]),
      int.parse(args[3]),
      int.parse(args[2]),
      int.tryParse(args[1].substring(0, 2))??0,
      int.tryParse(args[1].substring(2, 4))??0,
      int.tryParse(args[1].substring(4, 6))??0 // actually a double? secs and fractions of a second
  ),
        super (args);
}
// Transducer measurement
class XDR extends NMEA {
  XDR(final List<String> args) : super(args);
}

/// Depth below transducer
///

/// 1   2 3   4 5   6 7
/// |   | |   | |   | |
/// $--DBT,x.x,f,x.x,M,x.x,F*hh<CR><LF>

/// Field Number:
/// 1 Water depth, feet
/// 2 f = feet
/// 3 Water depth, meters
/// 4 M = meters
/// 5 Water depth, Fathoms
/// 6 F = Fathoms
/// 7 Checksum
class DBT extends NMEA {
  double? feet, metres, fathoms;

  DBT(final List<String> args) :
        feet = _d(args[1]),
        metres = _d(args[3]),
        fathoms = _d(args[5]),
        super(args);
}

//
//    DPT - Depth of Water
//
//           1   2   3   4
//           |   |   |   |
//    $--DPT,x.x,x.x,x.x*hh<CR><LF>
//
//    Field Number:
//    1   Water depth relative to transducer, meters
//    2   Offset from transducer, meters positive means distance from tansducer to water line negative means distance from transducer to keel
//    3   Maximum range scale in use (NMEA 3.0 and above)
//    4   Checksum

// There's a bug in some Navico devices that reports negative offsets as (e.g) -1.-7 when it should be -1.7
// We just replace .- with .
// However, if the offset is given as 0.-7, that means -0.7

class DPT extends NMEA {
  final double? depthTransducer;
  final double offset;
  DPT(final List<String> args) :
        depthTransducer = _d(args[1]),
        offset = _dx(args[2]),
        super(args);

  static double _dx(String v) {
    if (v.startsWith("0.-")) {
      return double.tryParse("-0." + v.substring(3))??0;
    }
    return double.tryParse(v.replaceFirst("\.-", "."))??0;
  }

  double? get depthSurface => depthTransducer== null ? null : offset > 0 ? depthTransducer!+offset : null;
  double? get depthKeel => depthTransducer== null ? null : offset < 0 ? depthTransducer!+offset : null;
}

class DBK extends NMEA {
  final double? depthKeel;

  DBK(final List<String> args) :
        depthKeel = _d(args[1]),
        super(args);
}

class DBS extends NMEA {
  final double? depthSurface;

  DBS(final List<String> args) :
        depthSurface = _d(args[1]),
        super(args);
}

///
/// HDG - Heading - Deviation & Variation
///        1   2   3 4   5
///        |   |   | |   |
/// $--HDG,x.x,x.x,a,x.x,a*hh<CR><LF>
/// Field Number:
/// 1. Magnetic Sensor heading in degrees
/// 2. Magnetic Deviation, degrees
/// 3. Magnetic Deviation direction, E = Easterly, W = Westerly
/// 4. Magnetic Variation degrees
/// 5. Magnetic Variation direction, E = Easterly, W = Westerly
class HDG extends NMEA {
  final double? heading;
  double deviation, variation;

  HDG(final List<String> args) :
        heading = _d(args[1]),
        deviation = _deg(args[2], args[3])??0,
        variation = _deg(args[4], args[5])??0,
        super(args);

  @override String toString() {
    return heading == null ? 'Unknown' : heading!.toStringAsFixed(1) + "° " + super.toString();
  }

  static double? _deg(String d, String ew) {
    double? r = _d(d);
    if (r == null) { return null; }
    return r * (ew == "W" ? -1 : 1);
  }
  double? get trueHeading => heading == null ? null : (heading! + deviation + variation);
}

// true heading
class HDT extends NMEA {
  final double? heading;

  HDT(final List<String> args) :
        heading = _d(args[1]),
        super(args);

  @override String toString() {
    return heading == null ? 'Unknown' : (heading!.toStringAsFixed(1) + "° " + super.toString());
  }
}

/// Mean Water Temp, not implemented
class MTW extends NMEA {
  MTW(final List<String> args) : super(args);
}

/// VHW - Water speed and heading
/// 1   2 3   4 5   6 7   8 9
/// |   | |   | |   | |   | |
/// $--VHW,x.x,T,x.x,M,x.x,N,x.x,K*hh<CR><LF>
/// Field Number:
/// 1 Heading degrees, True
/// 2 T = True
/// 3 Heading degrees, Magnetic
/// 4 M = Magnetic
/// 5 Speed of vessel relative to the water, knots
/// 6 N = Knots
/// 7 Speed of vessel relative to the water, km/hr
/// 8 K = Kilometers
/// 9 Checksum

class VHW extends NMEA {
  final double? headingTrue, headingMagnetic, boatspeedKnots, boatSpeedKmh;

  VHW(final List<String> args) :
        headingTrue = _d(args[1]),
        headingMagnetic = _d(args[3]),
        boatspeedKnots = _d(args[5]),
        boatSpeedKmh = _d(args[7]),
        super(args);
}

/// VLW - Distance Traveled through Water
/// 1   2 3   4 5   6  7  8  9
/// |   | |   | |   |  |  |  |
/// $--VLW,x.x,N,x.x,N,x.x,N,x.x,N*hh<CR><LF>
/// Field Number:
/// 1. Total cumulative water distance, nm
/// 2. N = Nautical Miles
/// 3. Water distance since Reset, nm
/// 4. N = Nautical Miles
/// 5. Total cumulative ground distance, nm (NMEA 3 and above)
/// 6. N = Nautical Miles (NMEA 3 and above)
/// 7. Ground distance since reset, nm (NMEA 3 and above)
/// 8. N = Nautical Miles (NMEA 3 and above)
/// 9. Checksum
class VLW extends NMEA {
  double? cumulativeDistance, resetDistance, cumulativeGroundDistance, resetGroundDistance;
  VLW(final List<String> args) :
        cumulativeDistance = _d(args[1]),
        resetDistance = _d(args[3]),
        cumulativeGroundDistance = _d(args[5]),
        resetGroundDistance = _d(args[7]),
        super(args);
}

/// Wind speed and Direction
///        1   2 3   4 5
///        |   | |   | |
/// $--MWD,x.x,a,x.x,a*hh<CR><LF>
/// Field Number:
/// 1 Wind Direction, 0 to 359 degrees
/// 2 T = True
/// 3 Wind Direction, 0 to 359 degrees
/// 4 M = Magnetic
/// 5 Wind Speed
/// 6 Wind Speed Units (N)
/// 7 Wind Speed
/// 8 Wind Speed Units (M)
/// 9 Status, A = Data Valid, V = Invalid
/// 10 Checksum
class MWD extends NMEA {
  final double? trueWindDirection, trueWindSpeedKnots;
  MWD(final List<String> args) :
        trueWindDirection = _d(args[1]),
        trueWindSpeedKnots = _d(args[5]),
        super(args);
}

/// MWV - Wind Speed and Angle
///        1   2 3   4 5
///        |   | |   | |
/// $--MWV,x.x,a,x.x,a*hh<CR><LF>
/// Field Number:
/// 1 Wind Angle, 0 to 359 degrees
/// 2 Reference, R = Relative, T = True
/// 3 Wind Speed
/// 4 Wind Speed Units, K/M/
/// 5 Status, A = Data Valid, V = Invalid
/// 6 Checksum
///

// Seems like 'T' means TWA, 'R' means AWA
// and these are indeed 0..360, not 'from the bow, hence the 'windAngleToBow' getter.

class MWV extends NMEA {
  final double? windAngle, windSpeed;
  final bool isTrue;
  MWV(final List<String> args) :
        windAngle = _d(args[1]),
        windSpeed = _d(args[3]),
        isTrue = ('T' == args[2]),
        super(args);

  double? get windAngleToBow => windAngle ?? (windAngle! > 180 ? 360-windAngle! : windAngle);
  String? get tack => windAngle == null ? null : (windAngle! >= 180 ? 'Port' : 'Starboard') ;
}

// Waypoint location, not yet used?
class WPL extends NMEA {
  WPL(final List<String> args) : super(args);
}

// This is a set of sentence types that have been seen and already noted as unhandled.
// it's maintained cumulatively to avoid endless repeated error messages.
Set<String> _seen = Set();

// Accepts a raw string, and attempts a basic parse of the message
// then selectively constructs a derivative class of NMEA from it representing the specific message type.
NMEA? _sentence(String event) {
  List<String> s = event.split(",");
  if (s.length == 0 || s[0].length <= 3) {
    print("Sentence error: " + event);
    return null;
  }
  if (invalidChecksum(event)) {
    // print("Checksum invalid: $event");
  }

  String sentence = s[0].substring(3);

  // separate last field from checksum
  var split = s[s.length-1].split("*");

  s[s.length-1] = split[0];
  s.add(split[1]);

  switch (sentence) {
    case r'VDM': return VDM(s);
    case r'AAM': return AAM(s);
    case r'APB': return APB(s);
    case r'BOD': return BOD(s);
    case r'BWR': return BWR(s);
    case r'BWC': return BWC(s);
    case r'GGA': return GGA(s);
    case r'GLL': return GLL(s);
    case r'GLC': return GLC(s);
    case r'GSA': return GSA(s);
    case r'GSV': return GSV(s);
    case r'RMB': return RMB(s);
    case r'RMC': return RMC(s);
    case r'VTG': return VTG(s);
    case r'XTE': return XTE(s);
    case r'ZDA': return ZDA(s);
    case r'XDR': return XDR(s);
    case r'DBT': return DBT(s);
    case r'DPT': return DPT(s);
    case r'DBK': return DBK(s);
    case r'DBS': return DBS(s);
    case r'HDG': return HDG(s);
    case r'HDT': return HDT(s);
    case r'MTW': return MTW(s);
    case r'VHW': return VHW(s);
    case r'VLW': return VLW(s);
    case r'MWD': return MWD(s);
    case r'MWV': return MWV(s);
    case r'VDO': return VDO(s);
    case r'WPL': return WPL(s);


    default:
      if (!_seen.contains(sentence)) {
        // unhandled sentence type - this is OK.
        _seen.add(sentence);
        print("Warning, unhandled sentence types that have been seen ${_seen.toString()}");
      }
      return null;
  }
}

// The Checksum is mandatory, and the last field in a sentence.
// It is the 8-bit XOR of all characters in the sentence, excluding the "$", "I", or "*" characters;
// but including all "," and "^". It is encoded as two hexadecimal characters (0-9, A-F), the most-significant-nibble being sent first.
bool invalidChecksum(final String event) {
  int? expect = int.tryParse(event.substring(event.length-2), radix:16);
  int got = checksum(event);
  if (got != expect) {
    // print("BAD [${got.toRadixString(16)}][${expect.toRadixString(16)}][$event]");
  }
  return got == expect;
}

/// compute checksum for a sentence - *must* include the whole sentence
/// including leading $ or !, and the *XX checksum even though these are not counted
/// in the checksum itself
int checksum(final String event) {
  int got = 0;
  for (int i=1; i<event.length-3; i++) {
    switch (event[i]) {
      case r'$':
      case '!':
      case '*':
        continue;
    }
    got ^= event.codeUnitAt(i);
  }
  return got;
}
