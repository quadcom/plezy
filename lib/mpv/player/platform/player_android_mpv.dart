import '../player_native.dart';
import '../video_rect_support.dart';

/// libmpv on Android. The video plane sits behind the Flutter view and fills
/// it, except where Flutter places it elsewhere (Old School's corner window,
/// PLAN_SHA_21; see [VideoRectSupport]).
class PlayerAndroidMpv extends PlayerNative with VideoRectSupport {
  PlayerAndroidMpv({super.hardwareDecoding});
}
