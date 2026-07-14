/// Clip sense 앱 진입점. GPS 교차로 선택 → 안내로 배선.
library;

import 'package:flutter/material.dart';

import 'feedback/speech_output.dart';
import 'feedback/haptic_output.dart';
import 'feedback/feedback_controller.dart';
import 'app/location_service.dart';
import 'app/selection_screen.dart';

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
      ),
    );
  }
}
