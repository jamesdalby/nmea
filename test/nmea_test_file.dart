import 'dart:io';

import 'package:nmea/nmea.dart';

  void main(final List<String> args) {
    NMEAReader nmea = new NMEADummy.from(File(args[0]));
    nmea.process(print);
  }
