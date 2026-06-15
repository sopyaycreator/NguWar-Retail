import 'package:flutter/material.dart';
import 'db_helper.dart';

class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key});

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  final GlobalKey<RefreshIndicatorState> _refreshKey =
      GlobalKey<RefreshIndicatorState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F6F6),
      appBar: AppBar(
        title: const Text("Inventory"),
        centerTitle: true,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "📦 Inventory",
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: RefreshIndicator(
                  key: _refreshKey,
                  onRefresh: () async {
                    setState(() {});
                  },
                  child: FutureBuilder<List<Map<String, Object?>>>(
                    future: DBHelper.getItems(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      if (!snapshot.hasData || snapshot.data!.isEmpty) {
                        return ListView(
                          children: const [
                            SizedBox(height: 100),
                            Center(
                              child: Text(
                                "No products stored in database. Add them in the drawer.",
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey),
                              ),
                            ),
                          ],
                        );
                      }

                      final storeItems = snapshot.data!;

                      return ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: storeItems.length,
                        itemBuilder: (context, index) {
                          final item = storeItems[index];

                          final int stockQty =
                              (item['quantity'] as num?)?.toInt() ?? 0;
                          final double unitPrice =
                              (item['priceUnit'] as num?)?.toDouble() ?? 0.0;
                          final int trackStock =
                              (item['trackStock'] as num?)?.toInt() ?? 1;
                          final int saleEffect =
                              (item['saleEffect'] as num?)?.toInt() ?? 1;

                          final String badgeText = trackStock == 1
                              ? "Stock: $stockQty"
                              : (saleEffect == -1 ? "Deduct" : "Non-stock");

                          final Color badgeBg = trackStock == 1
                              ? (stockQty > 0
                                  ? Colors.blue.shade50
                                  : Colors.red.shade50)
                              : (saleEffect == -1
                                  ? Colors.red.shade50
                                  : Colors.orange.shade50);

                          final Color badgeTextColor = trackStock == 1
                              ? (stockQty > 0
                                  ? Colors.blue.shade900
                                  : Colors.red)
                              : (saleEffect == -1
                                  ? Colors.red.shade900
                                  : Colors.orange.shade900);

                          return Card(
                            color: Colors.white,
                            elevation: 0.5,
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              dense: true,
                              title: Text(
                                "${item['name'] ?? 'Unknown Item'}",
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text("ID: ${item['barcode'] ?? '-'}"),
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: badgeBg,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      badgeText,
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: badgeTextColor,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "${unitPrice.toStringAsFixed(0)} MMK / each",
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade600,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}