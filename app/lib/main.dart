/// Clip sense 앱 진입점. GPS 교차로 선택 → 안내로 배선.
library;

import 'package:flutter/material.dart';

import 'feedback/speech_output.dart';
import 'feedback/haptic_output.dart';
import 'feedback/feedback_controller.dart';
import 'app/config.dart';
import 'app/demo_signal.dart';
import 'app/location_service.dart';
import 'app/selection_screen.dart';
import 'app/vision_source_factory.dart';

void main() {
  runApp(const ClipSenseApp());
}

class ClipSenseApp extends StatelessWidget {
  const ClipSenseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Clip sense',
      debugShowCheckedModeBanner: false,
      home: SelectionScreen(
        location: GeolocatorLocationService(),
        feedbackFactory: () =>
            FeedbackController(FlutterTtsSpeech(), VibrationHaptic()),
        // CLIP_CAM_HOST 가 주어지면 옷깃 클립 카메라(HTTP 스냅샷), 아니면 폰 카메라.
        visionFactory: () =>
            defaultVisionSource(host: kClipCamHost, token: kClipCamToken),
        // DEMO_SIGNAL=cycle 이면 시연용 가정 신호(화면에 표시), 아니면 실제 API.
        fetchFactory: () => demoSignalFetch(kDemoSignal),
      ),
    );
  }
}
