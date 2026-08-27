/// GPS로 최근접 교차로를 자동 선택하고, 방향을 사용자가 큰버튼 목록에서 고른다.
/// GPS 실패·근처 없음은 정직하게 안내(추측 금지). 방향 선택 후 GuidanceScreen으로.
library;

import 'package:flutter/material.dart';

import '../camera/camera_vision_source.dart';
import '../feedback/feedback_controller.dart';
import 'guidance_controller.dart';
import 'guidance_screen.dart';
import 'intersection.dart';
import 'intersection_finder.dart';
import 'location_service.dart';

enum _Phase { locating, chooseDirection, denied, unavailable, notFound }

class SelectionScreen extends StatefulWidget {
  final LocationService location;
  final FeedbackController Function() feedbackFactory;
  final VisionSource Function()? visionFactory;
  final List<Intersection> intersections;
  const SelectionScreen({
    super.key,
    required this.location,
    required this.feedbackFactory,
    this.visionFactory,
    this.intersections = kIntersections,
  });

  @override
  State<SelectionScreen> createState() => _SelectionScreenState();
}

class _SelectionScreenState extends State<SelectionScreen> {
  _Phase _phase = _Phase.locating;
  Intersection? _found;
  bool _navigating = false;

  @override
  void initState() {
    super.initState();
    _locate();
  }

  Future<void> _locate() async {
    setState(() => _phase = _Phase.locating);
    final r = await widget.location.current();
    if (!mounted) return;
    switch (r) {
      case LocationOk(:final lat, :final lng):
        final it = nearest(lat, lng, widget.intersections);
        setState(() {
          if (it == null) {
            _phase = _Phase.notFound;
          } else {
            _found = it;
            _phase = _Phase.chooseDirection;
          }
        });
      case LocationDenied():
        setState(() => _phase = _Phase.denied);
      case LocationUnavailable():
        setState(() => _phase = _Phase.unavailable);
    }
  }

  void _choose(Intersection it, Direction dir) {
    // 저시력·운동장애 사용자의 빠른 연속 탭(더블탭)이 GuidanceScreen을 두 번
    // push해 GuidanceController(및 feedbackFactory())가 중복 생성되는 것을 막는다.
    if (_navigating) return;
    _navigating = true;
    final controller = GuidanceController(
      feedback: widget.feedbackFactory(),
      itstId: it.itstId,
      direction: dir.code,
      vision: widget.visionFactory?.call() ?? CameraVisionSource(),
    );
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) =>
                GuidanceScreen(controller: controller, disposeController: true),
          ),
        )
        .then((_) {
          if (mounted) _navigating = false;
        });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF222222),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    switch (_phase) {
      case _Phase.locating:
        return _message('위치를 확인하는 중입니다');
      case _Phase.denied:
        return _messageWithRetry('위치 권한이 필요합니다');
      case _Phase.unavailable:
        return _messageWithRetry('위치를 확인할 수 없습니다');
      case _Phase.notFound:
        return _messageWithRetry('근처 교차로를 찾을 수 없습니다');
      case _Phase.chooseDirection:
        return _directionList(_found!);
    }
  }

  Widget _message(String text) => Center(
    child: Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
      ),
    ),
  );

  /// 큰버튼. 터치는 GestureDetector가, 스크린리더(TalkBack/VoiceOver)의 두 번
  /// 탭은 Semantics.onTap이 받는다. excludeSemantics로 자식 트리를 접근성
  /// 트리에서 빼기 때문에 GestureDetector의 탭 액션은 노출되지 않는다 —
  /// onTap을 Semantics 노드 자체에 달아야 활성화가 실제 동작으로 이어진다.
  Widget _bigButton({
    required String label,
    required VoidCallback onTap,
    required Color color,
    double fontSize = 34,
    FontWeight fontWeight = FontWeight.w900,
    double verticalPadding = 32,
  }) => Semantics(
    button: true,
    label: label,
    onTap: onTap,
    excludeSemantics: true,
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(vertical: verticalPadding),
        color: color,
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: fontWeight,
            color: Colors.white,
          ),
        ),
      ),
    ),
  );

  Widget _messageWithRetry(String text) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Expanded(child: _message(text)),
      Padding(
        padding: const EdgeInsets.all(16),
        child: _bigButton(
          label: '다시 시도',
          onTap: _locate,
          color: const Color(0xFF3A3A3A),
          fontSize: 30,
          fontWeight: FontWeight.w800,
          verticalPadding: 28,
        ),
      ),
    ],
  );

  Widget _directionList(Intersection it) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(20),
        child: Semantics(
          liveRegion: true,
          child: Text(
            '${it.name}\n건널 방향을 선택하세요',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        ),
      ),
      Expanded(
        child: ListView(
          children: [
            for (final dir in it.directions)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: _bigButton(
                  label: dir.label,
                  onTap: () => _choose(it, dir),
                  color: const Color(0xFF0A5FA8),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}
