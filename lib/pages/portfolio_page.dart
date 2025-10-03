import 'package:flutter/material.dart';

class PortfolioPage extends StatelessWidget {
  const PortfolioPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: const Text("Danh mục", style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.blue),
      body: const Center(
          child: Text("Your portfolio will be displayed here.",
              style: TextStyle(fontSize: 16))),
    );
  }
}
