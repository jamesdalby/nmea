import 'package:nmea/nmea.dart';

  void main(final List<String> args) {
    NMEAReader nmea = new NMEAReader(args[0], int.parse(args[1]));
    nmea.process(print);
  }
