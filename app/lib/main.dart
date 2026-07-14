/// Clip sense 앱 진입점. 엔진(실API→판단→음성/햅틱)을 접근성 화면에 배선한다.
library;

import 'package:flutter/material.dart';

import 'feedback/speech_output.dart';
import 'feedback/haptic_output.dart';
import 'feedback/feedback_controller.dart';
import 'app/guidance_controller.dart';
import 'app/guidance_screen.dart';

void main() {
  final feedback = FeedbackController(FlutterTtsSpeech(), VibrationHaptic());
  final controller = GuidanceController(feedback: feedback);
  runApp(ClipSenseApp(controller: controller));
}

class ClipSenseApp extends StatelessWidget {
  final GuidanceController controller;
  const ClipSenseApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Clip sense',
      debugShowCheckedModeBanner: false,
      home: GuidanceScreen(controller: controller),
    );
  }
}
