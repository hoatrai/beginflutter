import 'package:flutter/material.dart';

class MarketPage extends StatelessWidget {
  const MarketPage({super.key});

  final List<Map<String, dynamic>> coins = const [
    {"name": "Bitcoin", "symbol": "BTC", "price": "65,200", "change": "+2.3%"},
    {"name": "Ethereum", "symbol": "ETH", "price": "3,200", "change": "-1.1%"},
    {"name": "Binance Coin", "symbol": "BNB", "price": "450", "change": "+0.8%"},
    {"name": "Solana", "symbol": "SOL", "price": "150", "change": "+5.4%"},
    {"name": "Ripple", "symbol": "XRP", "price": "0.52", "change": "-0.6%"},
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: const Text("Crypto Market", style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.blue),
      body: ListView.builder(
        itemCount: coins.length,
        padding: const EdgeInsets.all(12),
        itemBuilder: (context, index) {
          final coin = coins[index];
          final bool isPositive = coin["change"].toString().contains("+");

          return Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.symmetric(vertical: 8),
            elevation: 4,
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: CircleAvatar(
                radius: 24,
                backgroundColor: Colors.blue.shade100,
                child: Text(coin["symbol"], style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              title: Text(coin["name"],
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              subtitle: Text("Price: \$${coin["price"]}"),
              trailing: Text(
                coin["change"],
                style: TextStyle(
                  color: isPositive ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
