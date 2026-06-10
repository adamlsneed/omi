import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:omi/pages/apps/explore_install_page.dart';
import 'package:omi/pages/apps/providers/add_app_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';

class AppsPage extends StatefulWidget {
  final bool showAppBar;
  const AppsPage({super.key, this.showAppBar = false});

  @override
  State<AppsPage> createState() => AppsPageState();
}

class AppsPageState extends State<AppsPage> with AutomaticKeepAliveClientMixin {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<ExploreInstallPageState> _exploreInstallPageKey = GlobalKey<ExploreInstallPageState>();

  @override
  void initState() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AddAppProvider>().getCategories();
    });
    super.initState();
  }

  void scrollToTop() {
    _exploreInstallPageKey.currentState?.scrollToTop();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.primary,
      appBar: widget.showAppBar
          ? AppBar(
              backgroundColor: Theme.of(context).colorScheme.primary,
              automaticallyImplyLeading: true,
              title: Text(context.l10n.apps),
              centerTitle: true,
              elevation: 0,
            )
          : null,
      body: DefaultTabController(
        length: 1,
        initialIndex: 0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // TabBar(
            //   indicatorSize: TabBarIndicatorSize.label,
            //   isScrollable: true,
            //   padding: EdgeInsets.zero,
            //   indicatorPadding: EdgeInsets.zero,
            //   labelStyle: Theme.of(context).textTheme.titleLarge!.copyWith(fontSize: 18),
            //   indicatorColor: Colors.white,
            //   tabs: const [
            //     Tab(text: 'Explore & Install'),
            //     Tab(text: 'Manage & Create'),
            //   ],
            // ),
            Expanded(
              child: ExploreInstallPage(key: _exploreInstallPageKey, scrollController: _scrollController),
            ),
            // const Expanded(
            //     child: TabBarView(
            //   children: [
            //     ExploreInstallPage(),
            //     ManageCreatePage(),
            //   ],
            // )),
          ],
        ),
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
