# nmea
NMEA reader and decoder

Read NMEA0183 from a TCP/IP source and decoded into Dart class instances.
Several most frequently used message types, but *not all* are decoded currently.

# Messages
The following messages are accepted; those emboldened are fully decoded:
AAM,
APB,
BOD,
**DBK**,
**DBS**,
**DBT**,
**DPT**,
**GGA**,
GLC,
**GLL**,
GSA,
GSV,
**HDG**,
**HDT**,
MTW,
**MWD**,
**MWV**,
**RMB**,
**RMC**,
**VDM**,
**VDO**,
**VHW**,
**VLW**,
**VTG**,
WPL,
XDR,
**XTE**,
**ZDA**


# See also

* [https://github.com/jamesdalby/ais] for AIS VDM/VDO decoding
* [https://gpsd.gitlab.io/gpsd/NMEA.html] NMEA protocol information
* [https://github.com/jamesdalby/jamais] an AIS display application
* [https://github.com/jamesdalby/kanivis] an application for blind and visually impaired sailors that speak aloud various boat data

# Contributors

If you wish to contribute to the code base, you'd be most welcome, please contact me
through github [https://github.com/jamesdalby] in the first instance

