import 'package:flutter/material.dart';

import 'views/diagnose_screen.dart';

class FieldOpsApp extends StatelessWidget {
  const FieldOpsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FieldOps Copilot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B6E4F)),
        useMaterial3: true,
      ),
      // Task 1.11 replaced the Tier 0 skeleton (`HomeScreen`, deleted) with the
      // demo screen. Two screens would have meant one that streams a scripted
      // fake next to one that runs the model, which is the "looks like it worked"
      // hazard `agentEngineProvider` exists to close.
      home: const DiagnoseScreen(),
    );
  }
}
