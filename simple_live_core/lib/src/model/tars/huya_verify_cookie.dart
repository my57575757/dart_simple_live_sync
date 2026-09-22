import 'package:tars_dart/tars/codec/tars_displayer.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';

class HuyaVerifyCookieReq extends TarsStruct {
  int lUid = 0;
  String sUA = "";
  String sCookie = "";
  String sGuid = "";

  @override
  void readFrom(TarsInputStream _is) {
    lUid = _is.read(lUid, 0, false);
    sUA = _is.read(sUA, 1, false);
    sCookie = _is.read(sCookie, 2, false);
    sGuid = _is.read(sGuid, 3, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lUid, 0);
    _os.write(sUA, 1);
    _os.write(sCookie, 2);
    _os.write(sGuid, 3);
  }

  @override
  Object deepCopy() => HuyaVerifyCookieReq()
    ..lUid = lUid
    ..sCookie = sCookie;

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer(sb, level: level).DisplayInt(lUid, "lUid");
  }
}

class HuyaVerifyCookieRsp extends TarsStruct {
  int iValidate = -1;

  @override
  void readFrom(TarsInputStream _is) {
    iValidate = _is.read(iValidate, 0, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(iValidate, 0);
  }

  @override
  Object deepCopy() => HuyaVerifyCookieRsp()..iValidate = iValidate;

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer(sb, level: level).DisplayInt(iValidate, "iValidate");
  }
}
