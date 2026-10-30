/// Why the server converted a play, grouped the way the player explains it.
enum ServerConversionReason {
  /// Over the server's bitrate cap: for a play outside the house, its remote limit.
  bitrateLimit,

  /// The sound is converted (codec, channels, sample rate and the like).
  sound,

  /// The picture format cannot be played as is (codec, profile, level, HDR type and the like).
  picture,

  /// Subtitles are painted into the picture.
  subtitles,

  /// A disc image has no clean file to play, so it is always converted.
  discImage,
}

/// What the server sends instead of the file, read from the `TranscodingUrl` it
/// negotiated. The player shows this rather than the chosen quality, so a play
/// the server converted on its own never reads as "Original".
class ServerConversion {
  const ServerConversion({
    this.bitrateKbps,
    this.maxWidth,
    this.maxHeight,
    this.reasonCodes = const [],
    required this.forced,
    this.isDiscImage = false,
  });

  /// Video plus audio bitrate the server was asked to send, when it says.
  final int? bitrateKbps;

  /// Size caps carried in the URL; the player's own decoded size wins once known.
  final int? maxWidth;
  final int? maxHeight;

  /// The server's `TranscodeReasons` codes, as sent.
  final List<String> reasonCodes;

  /// True when the user picked Original and the server converted anyway.
  final bool forced;

  final bool isDiscImage;

  static ServerConversion fromTranscodingUrl(String url, {required bool forced, bool isDiscImage = false}) {
    final query = Uri.tryParse(url)?.queryParameters ?? const <String, String>{};
    int? number(String key) => int.tryParse(query[key] ?? '');
    final videoBps = number('VideoBitrate');
    final audioBps = number('AudioBitrate');
    final totalBps = videoBps == null && audioBps == null ? null : (videoBps ?? 0) + (audioBps ?? 0);
    final reasons = (query['TranscodeReasons'] ?? '')
        .split(',')
        .map((code) => code.trim())
        .where((code) => code.isNotEmpty)
        .toList(growable: false);
    return ServerConversion(
      bitrateKbps: totalBps == null || totalBps <= 0 ? null : (totalBps / 1000).round(),
      maxWidth: number('MaxWidth'),
      maxHeight: number('MaxHeight'),
      reasonCodes: reasons,
      forced: forced,
      isDiscImage: isDiscImage,
    );
  }

  /// The reasons worth telling the user, in a fixed order, without repeats.
  /// A bitrate cap is only news when the user asked for Original: a lower
  /// quality they picked themselves is the cap they chose.
  List<ServerConversionReason> get reasons {
    final found = <ServerConversionReason>{
      if (isDiscImage) ServerConversionReason.discImage,
      for (final code in reasonCodes) ?_reasonFor(code),
    };
    if (!forced) found.remove(ServerConversionReason.bitrateLimit);
    return ServerConversionReason.values.where(found.contains).toList(growable: false);
  }

  static ServerConversionReason? _reasonFor(String code) {
    switch (code) {
      case 'ContainerBitrateExceedsLimit':
      case 'VideoBitrateNotSupported':
        return ServerConversionReason.bitrateLimit;
      case 'SubtitleCodecNotSupported':
        return ServerConversionReason.subtitles;
    }
    if (code.startsWith('Audio') || code == 'SecondaryAudioNotSupported' || code == 'UnknownAudioStreamInfo') {
      return ServerConversionReason.sound;
    }
    if (code.startsWith('Video') ||
        code == 'RefFramesNotSupported' ||
        code == 'AnamorphicVideoNotSupported' ||
        code == 'InterlacedVideoNotSupported' ||
        code == 'UnknownVideoStreamInfo') {
      return ServerConversionReason.picture;
    }
    return null;
  }
}
