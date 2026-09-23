import 'package:tars_dart/tars/codec/tars_displayer.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';

import 'huya_user_id.dart';

class HuyaContentFormat extends TarsStruct {
  int iFontColor = 0;
  int iFontSize = 0;
  int iPopupStyle = 0;
  int iNickNameFontColor = 0;
  int iDarkFontColor = 0;
  int iDarkNickNameFontColor = 0;

  @override
  void readFrom(TarsInputStream _is) {
    iFontColor = _is.read(iFontColor, 0, false);
    iFontSize = _is.read(iFontSize, 1, false);
    iPopupStyle = _is.read(iPopupStyle, 2, false);
    iNickNameFontColor = _is.read(iNickNameFontColor, 3, false);
    iDarkFontColor = _is.read(iDarkFontColor, 4, false);
    iDarkNickNameFontColor = _is.read(iDarkNickNameFontColor, 5, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(iFontColor, 0);
    _os.write(iFontSize, 1);
    _os.write(iPopupStyle, 2);
    _os.write(iNickNameFontColor, 3);
    _os.write(iDarkFontColor, 4);
    _os.write(iDarkNickNameFontColor, 5);
  }

  @override
  Object deepCopy() => this;

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer(sb, level: level).DisplayInt(iFontColor, "iFontColor");
  }
}

class HuyaBulletFormat extends TarsStruct {
  int iFontColor = 0;
  int iFontSize = 0;
  int iTextSpeed = 0;
  int iTransitionType = 0;

  @override
  void readFrom(TarsInputStream _is) {
    iFontColor = _is.read(iFontColor, 0, false);
    iFontSize = _is.read(iFontSize, 1, false);
    iTextSpeed = _is.read(iTextSpeed, 2, false);
    iTransitionType = _is.read(iTransitionType, 3, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(iFontColor, 0);
    _os.write(iFontSize, 1);
    _os.write(iTextSpeed, 2);
    _os.write(iTransitionType, 3);
  }

  @override
  Object deepCopy() => this;

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer(sb, level: level).DisplayInt(iFontColor, "iFontColor");
  }
}

class HuyaMessageTagInfo extends TarsStruct {
  int iAppId = 1;
  String sTag = "";

  HuyaMessageTagInfo({this.iAppId = 1, this.sTag = ""});

  @override
  void readFrom(TarsInputStream _is) {
    iAppId = _is.read(iAppId, 0, false);
    sTag = _is.read(sTag, 1, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(iAppId, 0);
    _os.write(sTag, 1);
  }

  @override
  Object deepCopy() => HuyaMessageTagInfo(iAppId: iAppId, sTag: sTag);

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer(sb, level: level).DisplayString(sTag, "sTag");
  }
}

class HuyaUidNickName extends TarsStruct {
  int lUid = 0;
  String sNickName = "";

  @override
  void readFrom(TarsInputStream _is) {
    lUid = _is.read(lUid, 0, false);
    sNickName = _is.read(sNickName, 1, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lUid, 0);
    _os.write(sNickName, 1);
  }

  @override
  Object deepCopy() => HuyaUidNickName()
    ..lUid = lUid
    ..sNickName = sNickName;

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer(sb, level: level).DisplayString(sNickName, "sNickName");
  }
}

class HuyaSendMessageFormat extends TarsStruct {
  int iSenceType = 0;
  int lFormatId = 0;
  int lSizeTemplateId = 0;

  @override
  void readFrom(TarsInputStream _is) {
    iSenceType = _is.read(iSenceType, 0, false);
    lFormatId = _is.read(lFormatId, 1, false);
    lSizeTemplateId = _is.read(lSizeTemplateId, 2, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(iSenceType, 0);
    _os.write(lFormatId, 1);
    _os.write(lSizeTemplateId, 2);
  }

  @override
  Object deepCopy() => HuyaSendMessageFormat();

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer(sb, level: level).DisplayInt(iSenceType, "iSenceType");
  }
}

class HuyaSendMessageReq extends TarsStruct {
  HuyaUserId tUserId = HuyaUserId();
  int lTid = 0;
  int lSid = 0;
  String sContent = "";
  int iShowMode = 0;
  HuyaContentFormat tFormat = HuyaContentFormat();
  HuyaBulletFormat tBulletFormat = HuyaBulletFormat();
  List<HuyaUidNickName> vAtSomeone = [HuyaUidNickName()];
  int lPid = 0;
  List<HuyaMessageTagInfo> vTagInfo = [HuyaMessageTagInfo()];
  HuyaSendMessageFormat tSenceFormat = HuyaSendMessageFormat();
  int iMessageMode = 0;

  @override
  void readFrom(TarsInputStream _is) {
    tUserId = _is.read(tUserId, 0, false);
    lTid = _is.read(lTid, 1, false);
    lSid = _is.read(lSid, 2, false);
    sContent = _is.read(sContent, 3, false);
    iShowMode = _is.read(iShowMode, 4, false);
    tFormat = _is.read(tFormat, 5, false);
    tBulletFormat = _is.read(tBulletFormat, 6, false);
    vAtSomeone = _is.read(vAtSomeone, 7, false);
    lPid = _is.read(lPid, 8, false);
    vTagInfo = _is.read(vTagInfo, 9, false);
    tSenceFormat = _is.read(tSenceFormat, 10, false);
    iMessageMode = _is.read(iMessageMode, 11, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(tUserId, 0);
    _os.write(lTid, 1);
    _os.write(lSid, 2);
    _os.write(sContent, 3);
    _os.write(iShowMode, 4);
    _os.write(tFormat, 5);
    _os.write(tBulletFormat, 6);
    _os.writeList(vAtSomeone, 7);
    _os.write(lPid, 8);
    _os.writeList(vTagInfo, 9);
    _os.write(tSenceFormat, 10);
    _os.write(iMessageMode, 11);
  }

  @override
  Object deepCopy() => HuyaSendMessageReq()..sContent = sContent;

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer(sb, level: level).DisplayString(sContent, "sContent");
  }
}
