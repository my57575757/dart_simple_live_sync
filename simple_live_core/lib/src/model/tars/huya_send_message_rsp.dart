import 'package:tars_dart/tars/codec/tars_displayer.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';

class HuyaSendMessageStatus extends TarsStruct {
  int iStatus = 0;

  @override
  void readFrom(TarsInputStream _is) {
    iStatus = _is.read(iStatus, 0, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(iStatus, 0);
  }

  @override
  Object deepCopy() => HuyaSendMessageStatus()..iStatus = iStatus;

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer(sb, level: level).DisplayInt(iStatus, "iStatus");
  }
}

class HuyaSendMessageRsp extends TarsStruct {
  HuyaSendMessageStatus tStatus = HuyaSendMessageStatus();

  @override
  void readFrom(TarsInputStream _is) {
    tStatus = _is.read(tStatus, 0, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(tStatus, 0);
  }

  @override
  Object deepCopy() => HuyaSendMessageRsp()..tStatus = tStatus.deepCopy() as HuyaSendMessageStatus;

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer(sb, level: level).DisplayInt(tStatus.iStatus, "iStatus");
  }
}
