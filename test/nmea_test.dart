import 'package:nmea/nmea.dart';

void main(final List<String> args) {
  /* NMEASocketReader nmea = */ new NMEASocketReader(args[0], int.parse(args[1]), print);
}
