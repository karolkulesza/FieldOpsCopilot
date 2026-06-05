import 'package:flutter/material.dart';

import 'views/home_screen.dart';

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
      home: const HomeScreen(),
    );
  }
}
