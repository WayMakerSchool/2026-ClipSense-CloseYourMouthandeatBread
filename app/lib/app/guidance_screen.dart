/// 접근성 안내 화면. 화면 전체가 큰 버튼(탭 → 시작/정지 토글).
/// 상태별 고대비 색·초대형 글자·아이콘(A안) + 스크린리더 Semantics.
///
/// 전맹 사용자에겐 엔진 음성/햅틱이 이미 전달된다. 이 시각 표시는 저시력·도우미용,
/// Semantics 라벨은 전맹 사용자의 화면 조작(시작/정지 확인)용.
library;

import 'package:flutter/material.dart';

import '../signals/judge.dart';
import 'guidance_controller.dart';

class GuidanceScreen extends StatefulWidget {
  final GuidanceController controller;
  final bool disposeController;

  /// [disposeController]는 이 화면이 컨트롤러를 만든 route일 때만 true로 둔다.
  /// 테스트나 상위 위젯이 주입한 컨트롤러의 기존 소유권은 기본값(false)으로 유지한다.
  const GuidanceScreen({
    super.key,
    required this.controller,
    this.disposeController = false,
  });

  @override
  State<GuidanceScreen> createState() => _GuidanceScreenState();
}

class _GuidanceScreenState extends State<GuidanceScreen>
    with WidgetsBindingObserver {
  GuidanceController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 다른 앱·잠금화면·권한 다이얼로그로 영상 근거가 사라지면 즉시 정지한다.
    // 복귀 후에는 사용자가 카메라를 다시 조준하고 명시적으로 시작해야 한다.
    if (state != AppLifecycleState.resumed && controller.running) {
      controller.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.disposeController) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final v = _view(controller);
        return Scaffold(
          body: GestureDetector(
            onTap: controller.toggle,
            behavior: HitTestBehavior.opaque,
            // 버튼(탭 동작 + 상태 요약)과 상태 라이브 리전을 형제 노드로 분리.
            // 버튼 쪽 Semantics는 excludeSemantics로 내부 Text들의 개별 낭독을
            // 막아 라벨 하나로만 읽히게 하되, 상태 텍스트는 별도의
            // liveRegion 노드로 두어 excludeSemantics에 가려지지 않게 한다
            // (spec §4.3: 상태 전환 시 스크린리더가 재포커스 없이 자동 낭독).
            child: Semantics(
              key: const Key('guidanceButtonSemantics'),
              button: true,
              container: true,
              label: v.semanticLabel,
              child: Container(
                color: v.bg,
                width: double.infinity,
                height: double.infinity,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Semantics(
                      excludeSemantics: true,
                      child: v.icon != null
                          ? Text(v.icon!, style: const TextStyle(fontSize: 96))
                          : const SizedBox.shrink(),
                    ),
                    const SizedBox(height: 16),
                    Semantics(
                      key: const Key('guidanceLiveRegionSemantics'),
                      liveRegion: true,
                      container: true,
                      label: v.liveLabel,
                      excludeSemantics: true,
                      child: Column(
                        children: [
                          Text(
                            v.title,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 56,
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                            ),
                          ),
                          if (v.sub != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              v.sub!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _View {
  final Color bg;
  final String? icon;
  final String title;
  final String? sub;
  final String liveLabel;
  final String semanticLabel;
  _View(
    this.bg,
    this.icon,
    this.title,
    this.sub,
    this.liveLabel,
    this.semanticLabel,
  );
}

_View _view(GuidanceController c) {
  const tapStart = ' 두 번 탭하면 안내를 시작합니다.';
  const tapStop = ' 두 번 탭하면 안내를 정지합니다.';
  // 정지 화면은 running뿐 아니라 "아직 판정 없음"(decision==unknown)일 때도
  // 보인다. GuidanceController.tickOnce()는 running을 바꾸지 않고 decision만
  // 갱신하므로(테스트가 start() 없이 tickOnce()만으로 상태를 주입), running
  // 하나만으로는 "판정이 나온 정지 전 상태"를 구분할 수 없다. decision이
  // unknown이 아니면(walk/wait 판정이 있으면) running 여부와 무관하게 그
  // 판정을 그대로 보여준다.
  if (!c.running && c.decision == Decision.unknown) {
    if (!c.apiConfigured) {
      const liveLabel = '설정 오류. T-Data API 키가 없습니다. API 키를 넣어 다시 실행하세요.';
      return _View(
        const Color(0xFF5A5A5A),
        '⚙️',
        '설정 필요',
        'T-Data API 키가 없습니다',
        liveLabel,
        liveLabel,
      );
    }
    // liveLabel(상태만)과 semanticLabel(상태+조작 안내)이 같은 문구 조각을
    // 공유 — 아래서 tapStart/tapStop을 붙여 semanticLabel을 만든다(DRY).
    const liveLabel = '정지됨. 뒤 카메라를 보행 신호등으로 향하세요.';
    return _View(
      const Color(0xFF222222),
      null,
      '화면을 눌러\n안내를 시작하세요',
      '카메라를 신호등 중앙으로',
      liveLabel,
      '$liveLabel$tapStart',
    );
  }
  switch (c.decision) {
    case Decision.walk:
      final sub = c.remainSec != null ? '${c.remainSec!.round()}초' : null;
      final liveLabel = '건너세요.${sub != null ? " $sub 남음." : ""}';
      return _View(
        const Color(0xFF0A8F3C),
        '🚶',
        '건너세요',
        sub,
        liveLabel,
        '$liveLabel$tapStop',
      );
    case Decision.wait:
      final reason = decisionReasonText(c.reason);
      final liveLabel = '기다리세요. $reason.';
      return _View(
        const Color(0xFFC31414),
        '✋',
        '기다리세요',
        reason,
        liveLabel,
        '$liveLabel$tapStop',
      );
    case Decision.unknown:
      final reason = decisionReasonText(c.reason);
      final liveLabel = '$reason. 대기하세요.';
      return _View(
        const Color(0xFF5A5A5A),
        '❓',
        '확인 불가',
        reason,
        liveLabel,
        '$liveLabel$tapStop',
      );
  }
}
