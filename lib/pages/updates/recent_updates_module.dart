import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/updates/recent_updates_page.dart';

final recentUpdatesModule = createModule(
  path: '/updates',
  register: (c) {
    c.route(
      '/',
      transition: TransitionType.none,
      child: (context, state) => const RecentUpdatesPage(),
    );
  },
);
