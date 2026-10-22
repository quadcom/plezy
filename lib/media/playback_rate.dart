/// Inclusive playback-rate bounds supported by every in-app player backend.
const double minimumPlaybackRate = 0.25;
const double maximumPlaybackRate = 8.0;

/// A saved default speed as it should be applied. Every way to save one (the
/// speed menu, the speed keys stepping from 1x) lands on a quarter step, so
/// anything else is a leftover from an odd starting rate, such as an Old
/// School slow-down, and plays at normal speed instead
/// (local/plans/old-school-speed-leak.md).
double savedPlaybackRate(double rate) {
  final clamped = rate.clamp(minimumPlaybackRate, maximumPlaybackRate).toDouble();
  final quarters = clamped * 4;
  return (quarters - quarters.roundToDouble()).abs() < 0.001 ? clamped : 1.0;
}
