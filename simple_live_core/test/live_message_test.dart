import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  test("LiveMessage 默认非自我消息", () {
    var msg = LiveMessage(
      type: LiveMessageType.chat,
      userName: "路人",
      message: "666",
      color: LiveMessageColor.white,
    );
    expect(msg.isSelf, isFalse);
  });

  test("LiveMessage 可标记为自我消息", () {
    var msg = LiveMessage(
      type: LiveMessageType.chat,
      userName: "我",
      message: "hello",
      color: LiveMessageColor.white,
      isSelf: true,
    );
    expect(msg.isSelf, isTrue);
    expect(msg.toString(), contains('"isSelf":true'));
  });
}
