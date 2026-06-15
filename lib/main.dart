import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:nguwar/inventory_page.dart';
import 'package:nguwar/splash_screen.dart';
import 'package:nguwar/transaction_history_page.dart';
import 'db_helper.dart';
import 'item_history_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'POS Counter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.amber),
        useMaterial3: true,
      ),
      home: const SplashScreen(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _quantityController = TextEditingController();
  final TextEditingController _priceController = TextEditingController();
  final TextEditingController _barcodeController = TextEditingController();
  final TextEditingController _checkoutScanController = TextEditingController();

  final FocusNode _checkoutScanFocusNode = FocusNode();
  final List<Map<String, dynamic>> _activeCart = [];
  bool _hardwareScannerMode = false;
  bool _trackStock = true;
  int _saleEffect = 1;
  bool _isScanningCode = false;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _quantityController.dispose();
    _priceController.dispose();
    _barcodeController.dispose();
    _checkoutScanController.dispose();
    _checkoutScanFocusNode.dispose();
    super.dispose();
  }

  void _clearDrawerFields({bool resetTrackStock = false}) {
    _nameController.clear();
    _quantityController.clear();
    _priceController.clear();
    _barcodeController.clear();

    if (resetTrackStock) {
      _trackStock = true;
      _saleEffect = 1;
    }
  }

  // Future<void> _handleHardwareScanSubmit(String rawValue) async {
  //   final String barcode = rawValue.trim();
  //   if (barcode.isEmpty) {
  //     _requestHardwareScannerFocus();
  //     return;
  //   }

  //   await _handleProductScanned(context, barcode);

  //   _checkoutScanController.clear();
  //   if (_hardwareScannerMode) {
  //     _requestHardwareScannerFocus();
  //   }
  // }

  void _requestHardwareScannerFocus() {
    Future.delayed(const Duration(milliseconds: 80), () {
      if (mounted && _hardwareScannerMode) {
        _checkoutScanFocusNode.requestFocus();
      }
    });
  }

  void _activateHardwareScannerMode() {
    setState(() {
      _hardwareScannerMode = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("⌨️ Hardware scanner mode enabled. Start scanning now."),
        duration: Duration(seconds: 2),
      ),
    );

    _requestHardwareScannerFocus();
  }

  void _disableHardwareScannerMode() {
    setState(() {
      _hardwareScannerMode = false;
    });

    _checkoutScanFocusNode.unfocus();
  }

  Future<void> _saveItemFromDrawer() async {
    final String name = _nameController.text.trim();
    final String qtyRaw = _quantityController.text.trim();
    final String priceRaw = _priceController.text.trim();
    final String barcode = _barcodeController.text.trim();

    if (name.isEmpty || priceRaw.isEmpty || barcode.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("⚠️ Please fill required fields!")),
      );
      return;
    }

    if (_trackStock && qtyRaw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("⚠️ Stock quantity is required for stock items!"),
        ),
      );
      return;
    }

    try {
      await DBHelper.insertOrUpdateItem({
        'barcode': barcode,
        'name': name,
        'quantity': _trackStock ? (int.tryParse(qtyRaw) ?? 0) : 0,
        'priceUnit': double.tryParse(priceRaw) ?? 0.0,
        'trackStock': _trackStock ? 1 : 0,
        'saleEffect': _trackStock ? 1 : _saleEffect,
      });

      if (!mounted) return;

      _clearDrawerFields(resetTrackStock: true);
      Navigator.of(context).pop();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("✅ Item saved successfully!"),
          backgroundColor: Colors.green,
        ),
      );

      setState(() {});
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("❌ Save failed: $e"),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _scanProductBarcode() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (scannerContext) => Scaffold(
          appBar: AppBar(
            title: const Text("Scan Checkout Item"),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(scannerContext).pop(),
            ),
          ),
          body: MobileScanner(
            onDetect: (BarcodeCapture capture) async {
              if (_isScanningCode) return;

              final List<Barcode> barcodes = capture.barcodes;
              if (barcodes.isNotEmpty) {
                final String? code = barcodes.first.rawValue;
                if (code != null) {
                  setState(() {
                    _isScanningCode = true;
                  });

                  await _handleProductScanned(scannerContext, code);

                  await Future.delayed(const Duration(milliseconds: 1500));

                  if (mounted) {
                    setState(() {
                      _isScanningCode = false;
                    });
                  }
                }
              }
            },
          ),
        ),
      ),
    );
  }

  Future<void> _handleProductScanned(
    BuildContext context,
    String barcode,
  ) async {
    final Map<String, Object?>? matchedItem = await DBHelper.getItemByBarcode(
      barcode,
    );

    if (!context.mounted) return;

    if (matchedItem == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("❌ Item not found for barcode: $barcode"),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 1),
        ),
      );
      return;
    }

    final int totalAvailableStock =
        (matchedItem['quantity'] as num?)?.toInt() ?? 0;
    final int trackStock = (matchedItem['trackStock'] as num?)?.toInt() ?? 1;
    final int saleEffect = (matchedItem['saleEffect'] as num?)?.toInt() ?? 1;
    final String productName =
        matchedItem['name']?.toString() ?? 'Unknown Item';
    final double unitPrice =
        (matchedItem['priceUnit'] as num?)?.toDouble() ?? 0.0;

    final int basketIndex = _activeCart.indexWhere(
      (element) => element['barcode'] == barcode,
    );

    final int quantityInBasketAlready = basketIndex != -1
        ? ((_activeCart[basketIndex]['quantity'] as num?)?.toInt() ?? 0)
        : 0;

    if (trackStock == 1 && quantityInBasketAlready >= totalAvailableStock) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "⚠️ Cannot add $productName. Stock limit reached ($totalAvailableStock)!",
          ),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 1),
        ),
      );
      return;
    }

    setState(() {
      if (basketIndex != -1) {
        final int currentQty =
            (_activeCart[basketIndex]['quantity'] as num?)?.toInt() ?? 0;
        _activeCart[basketIndex]['quantity'] = currentQty + 1;
      } else {
        _activeCart.add({
          'barcode': barcode,
          'name': productName,
          'quantity': 1,
          'priceUnit': unitPrice,
          'trackStock': trackStock,
          'saleEffect': saleEffect,
        });
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          "➕ Added 1x $productName successfully! Total in basket: ${quantityInBasketAlready + 1}",
        ),
        backgroundColor: Colors.green,
        duration: const Duration(milliseconds: 800),
      ),
    );

    if (_hardwareScannerMode) {
      _requestHardwareScannerFocus();
    }
  }

  Future<void> _confirmCheckoutAndDeduct() async {
    if (_activeCart.isEmpty) return;

    final List<String> itemSummaries = [];
    double orderGrandTotal = 0.0;

    for (final cartItem in _activeCart) {
      final String barcode = cartItem['barcode']?.toString() ?? '';
      final Map<String, Object?>? dbItem = await DBHelper.getItemByBarcode(
        barcode,
      );

      if (dbItem != null) {
        final int trackStock = (dbItem['trackStock'] as num?)?.toInt() ?? 1;
        final int originalStock = (dbItem['quantity'] as num?)?.toInt() ?? 0;
        final int purchaseQty = (cartItem['quantity'] as num?)?.toInt() ?? 0;
        final int saleEffect = (cartItem['saleEffect'] as num?)?.toInt() ?? 1;
        final double priceUnit =
            (cartItem['priceUnit'] as num?)?.toDouble() ?? 0.0;
        final String name = cartItem['name']?.toString() ?? 'Unknown Item';

        if (trackStock == 1) {
          int absoluteNewStock = originalStock - purchaseQty;
          if (absoluteNewStock < 0) absoluteNewStock = 0;

          await DBHelper.updateItemQuantity(barcode, absoluteNewStock);
        }

        itemSummaries.add("${purchaseQty}x $name");
        orderGrandTotal += priceUnit * purchaseQty * saleEffect;
      }
    }

    await DBHelper.insertSale({
      'type': itemSummaries.join(", "),
      'price': orderGrandTotal,
      'saleDate': DateTime.now().toIso8601String(),
    });

    setState(() {
      _activeCart.clear();
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("🏁 Order confirmed!"),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  double _getCartTotalCost() {
    return _activeCart.fold(0.0, (sum, item) {
      final double price = (item['priceUnit'] as num?)?.toDouble() ?? 0.0;
      final int qty = (item['quantity'] as num?)?.toInt() ?? 0;
      final int saleEffect = (item['saleEffect'] as num?)?.toInt() ?? 1;

      return sum + (price * qty * saleEffect);
    });
  }

  Future<void> _handleHardwareScanSubmit(String rawValue) async {
    debugPrint("RAW SCAN: [$rawValue]");

    final String barcode = rawValue.trim();
    debugPrint("TRIMMED SCAN: [$barcode]");

    if (barcode.isEmpty) {
      _requestHardwareScannerFocus();
      return;
    }

    await _handleProductScanned(context, barcode);

    _checkoutScanController.clear();
    if (_hardwareScannerMode) {
      _requestHardwareScannerFocus();
    }
  }

  void _fillDrawerWithMatchedItem(Map<String, Object?> matched) {
    _nameController.text = matched['name']?.toString() ?? '';
    _priceController.text = ((matched['priceUnit'] as num?)?.toDouble() ?? 0.0)
        .toStringAsFixed(0);

    final int trackStock = (matched['trackStock'] as num?)?.toInt() ?? 1;
    final int qty = (matched['quantity'] as num?)?.toInt() ?? 0;
    final int saleEffect = (matched['saleEffect'] as num?)?.toInt() ?? 1;

    _trackStock = trackStock == 1;
    _saleEffect = saleEffect;
    _quantityController.text = qty.toString();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        key: _scaffoldKey,
        onDrawerChanged: (isOpened) {
          if (isOpened) {
            _checkoutScanFocusNode.unfocus();
          } else if (_hardwareScannerMode) {
            _requestHardwareScannerFocus();
          }
        },
        backgroundColor: const Color(0xFFF6F6F6),
        appBar: AppBar(
          title: const Text("🛒 Stock"),
          centerTitle: true,
          backgroundColor: Colors.amber,
          actions: [
            IconButton(
              icon: Icon(
                Icons.usb,
                color: _hardwareScannerMode
                    ? Colors.green.shade900
                    : Colors.black87,
              ),
              tooltip: 'Use Hardware Barcode Scanner',
              onPressed: _activateHardwareScannerMode,
            ),
            IconButton(
              icon: const Icon(Icons.qr_code_scanner, size: 28),
              tooltip: 'Use Phone Camera Scanner',
              onPressed: () {
                _disableHardwareScannerMode();
                _scanProductBarcode();
              },
            ),
            const SizedBox(width: 8),
          ],
        ),
        drawer: Drawer(
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.add_business, color: Colors.amber, size: 28),
                      SizedBox(width: 10),
                      Text(
                        "Add New Item",
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 30),
                  SwitchListTile(
                    title: const Text("Track Inventory Stock"),
                    subtitle: Text(
                      _trackStock
                          ? "This item reduces store stock"
                          : "This item is sellable but not stock-tracked",
                    ),
                    value: _trackStock,
                    onChanged: (value) {
                      setState(() {
                        _trackStock = value;
                        _clearDrawerFields();
                      });
                    },
                  ),
                  if (!_trackStock) ...[
                    DropdownButtonFormField<int>(
                      value: _saleEffect,
                      decoration: const InputDecoration(
                        labelText: "Non-stock behavior",
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 1, child: Text("Ice")),
                        DropdownMenuItem(value: -1, child: Text("Lottery cap")),
                      ],
                      onChanged: (value) {
                        setState(() {
                          _saleEffect = value ?? 1;
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _barcodeController,
                          decoration: const InputDecoration(
                            labelText: "Barcode (ID)",
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (value) async {
                            if (value.trim().isEmpty) return;

                            final matched = await DBHelper.getItemByBarcode(
                              value.trim(),
                            );

                            if (matched != null && mounted) {
                              setState(() {
                                _fillDrawerWithMatchedItem(matched);
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (dialogCtx) => AlertDialog(
                              title: const Text("Scan Stock Barcode"),
                              content: SizedBox(
                                width: double.maxFinite,
                                height: 300,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: MobileScanner(
                                    onDetect: (BarcodeCapture capture) async {
                                      final List<Barcode> barcodes =
                                          capture.barcodes;
                                      if (barcodes.isEmpty) return;

                                      final String? code =
                                          barcodes.first.rawValue;
                                      if (code == null) return;

                                      Navigator.of(dialogCtx).pop();

                                      setState(() {
                                        _barcodeController.text = code;
                                      });

                                      final matched =
                                          await DBHelper.getItemByBarcode(code);

                                      if (matched != null && mounted) {
                                        setState(() {
                                          _fillDrawerWithMatchedItem(matched);
                                        });
                                      }
                                    },
                                  ),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(dialogCtx).pop(),
                                  child: const Text("Cancel"),
                                ),
                              ],
                            ),
                          );
                        },
                        icon: const Icon(Icons.camera_alt),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: "Product Name",
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_trackStock) ...[
                    TextField(
                      controller: _quantityController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: "Quantity Stock",
                        helperText: "e.g., 10",
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  TextField(
                    controller: _priceController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: "Unit Price (Each Item)",
                      helperText: "e.g., 1000 MMK for each single item",
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: _saveItemFromDrawer,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber,
                      ),
                      icon: const Icon(Icons.save, color: Colors.black),
                      label: const Text(
                        "Save Item Data",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.black,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  GestureDetector(
                    onTap: () {
                      Navigator.of(context)
                          .push(
                            MaterialPageRoute(
                              builder: (context) => const ItemHistoryPage(),
                            ),
                          )
                          .then((_) {
                            setState(() {});
                          });
                    },
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 6.0),
                        color: Colors.transparent,
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              "📜 Full Item History",
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey,
                              ),
                            ),
                            Icon(
                              Icons.arrow_forward_ios,
                              size: 14,
                              color: Colors.grey,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        body: IndexedStack(
          index: _selectedIndex,
          children: [_buildHomeTab(), _buildInventoryTab()],
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _selectedIndex,
          onTap: (index) {
            setState(() {
              _selectedIndex = index;
            });
          },
          selectedItemColor: Colors.amber.shade900,
          unselectedItemColor: Colors.grey,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.home), label: "Home"),
            BottomNavigationBarItem(
              icon: Icon(Icons.inventory_2),
              label: "Inventory",
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeTab() {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        children: [
          Opacity(
            opacity: 0,
            child: SizedBox(
              width: 1,
              height: 1,
              child: TextField(
                controller: _checkoutScanController,
                focusNode: _checkoutScanFocusNode,
                autofocus: false,
                showCursor: false,
                enableInteractiveSelection: false,
                textInputAction: TextInputAction.done,
                onChanged: (value) {
                  debugPrint("Scanner typing: [$value]");
                },
                onSubmitted: _handleHardwareScanSubmit,
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  isCollapsed: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              "🛒 Scanned Basket List",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            flex: 3,
            child: _activeCart.isEmpty
                ? const Card(
                    child: Center(
                      child: Text(
                        "Basket is empty.\nScan with hardware scanner or tap the camera icon!",
                      ),
                    ),
                  )
                : Card(
                    color: Colors.white,
                    child: ListView.builder(
                      itemCount: _activeCart.length,
                      itemBuilder: (context, index) {
                        final cartItem = _activeCart[index];
                        final int saleEffect =
                            (cartItem['saleEffect'] as num?)?.toInt() ?? 1;
                        final double unitPrice =
                            (cartItem['priceUnit'] as num?)?.toDouble() ?? 0.0;
                        final int qty =
                            (cartItem['quantity'] as num?)?.toInt() ?? 0;
                        final String name =
                            cartItem['name']?.toString() ?? 'Unknown Item';

                        final double totalItemCost =
                            unitPrice * qty * saleEffect;

                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: saleEffect == -1
                                ? Colors.red.shade100
                                : Colors.amber.shade200,
                            child: Text(
                              "${qty}x",
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.black,
                              ),
                            ),
                          ),
                          title: Text(name),
                          subtitle: Text(
                            saleEffect == -1
                                ? "Deduct item: ${unitPrice.toStringAsFixed(0)} MMK"
                                : "Unit Price: ${unitPrice.toStringAsFixed(0)} MMK",
                          ),
                          trailing: Text(
                            "${totalItemCost.toStringAsFixed(0)} MMK",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: saleEffect == -1
                                  ? Colors.red
                                  : Colors.green,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          if (_activeCart.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(
                vertical: 10.0,
                horizontal: 4,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          "Total Amount",
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          "${_getCartTotalCost().toStringAsFixed(0)} MMK",
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.green,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: ElevatedButton.icon(
                      onPressed: _confirmCheckoutAndDeduct,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      icon: const Icon(Icons.done_all, size: 20),
                      label: const Text(
                        "Confirm",
                        style: TextStyle(fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const Divider(height: 24, thickness: 1),
          GestureDetector(
            onTap: () {
              Navigator.of(context)
                  .push(
                    MaterialPageRoute(
                      builder: (context) => const TransactionHistoryPage(),
                    ),
                  )
                  .then((_) {
                    setState(() {});
                  });
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 4.0),
                color: Colors.transparent,
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "📜 Completed Transaction Logs",
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Icon(
                      Icons.arrow_forward_ios,
                      size: 14,
                      color: Colors.black,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            flex: 3,
            child: FutureBuilder<List<Map<String, Object?>>>(
              future: DBHelper.getSales(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final historyLogs = snapshot.data!;
                if (historyLogs.isEmpty) {
                  return const Center(
                    child: Text(
                      "No transaction history records discovered yet.",
                    ),
                  );
                }

                final Map<String, List<Map<String, Object?>>> groupedLogs = {};

                for (final sale in historyLogs) {
                  final String rawDateStr = sale['saleDate']?.toString() ?? '';
                  final String dateKey = rawDateStr.length >= 10
                      ? rawDateStr.substring(0, 10)
                      : "Unknown Date";

                  groupedLogs.putIfAbsent(dateKey, () => []);
                  groupedLogs[dateKey]!.add(sale);
                }

                final List<String> sortedDates = groupedLogs.keys.toList();

                return ListView.builder(
                  itemCount: sortedDates.length,
                  itemBuilder: (context, dateIndex) {
                    final String dateHeader = sortedDates[dateIndex];
                    final List<Map<String, Object?>> dailySales =
                        groupedLogs[dateHeader]!;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8.0,
                            horizontal: 4.0,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade300,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              "📅 $dateHeader",
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey.shade800,
                              ),
                            ),
                          ),
                        ),
                        ...dailySales.map((saleRecord) {
                          final String saleDate =
                              saleRecord['saleDate']?.toString() ?? '';
                          final String timeDisplay = saleDate.length >= 16
                              ? saleDate.substring(11, 16)
                              : "00:00";

                          final String type =
                              saleRecord['type']?.toString() ?? '';
                          final double price =
                              (saleRecord['price'] as num?)?.toDouble() ?? 0.0;
                          final int id =
                              (saleRecord['id'] as num?)?.toInt() ?? 0;

                          return Card(
                            margin: const EdgeInsets.only(bottom: 6),
                            child: ListTile(
                              dense: true,
                              leading: const Icon(
                                Icons.receipt_long,
                                color: Colors.green,
                              ),
                              title: Text(
                                type,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              subtitle: Text(
                                "Time: $timeDisplay",
                                style: const TextStyle(fontSize: 11),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    "${price.toStringAsFixed(0)} MMK",
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.green,
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.delete,
                                      color: Colors.red,
                                      size: 16,
                                    ),
                                    onPressed: () async {
                                      await DBHelper.deleteSale(id);
                                      setState(() {});
                                    },
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInventoryTab() {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              "📦 Inventory",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: FutureBuilder<List<Map<String, Object?>>>(
              future: DBHelper.getItems(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final storeItems = snapshot.data!;
                if (storeItems.isEmpty) {
                  return const Center(
                    child: Text(
                      "No products stored in database. Add them in the drawer.",
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: storeItems.length,
                  itemBuilder: (context, index) {
                    final item = storeItems[index];
                    final int trackStock =
                        (item['trackStock'] as num?)?.toInt() ?? 1;
                    final int qty = (item['quantity'] as num?)?.toInt() ?? 0;
                    final int saleEffect =
                        (item['saleEffect'] as num?)?.toInt() ?? 1;
                    final double priceUnit =
                        (item['priceUnit'] as num?)?.toDouble() ?? 0.0;
                    final String name =
                        item['name']?.toString() ?? 'Unknown Item';
                    final String barcode = item['barcode']?.toString() ?? '-';

                    return Card(
                      color: Colors.white,
                      elevation: 0.5,
                      child: ListTile(
                        dense: true,
                        title: Text(
                          name,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: Text("ID: $barcode"),
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
                                color: trackStock == 1
                                    ? (qty > 0
                                          ? Colors.blue.shade50
                                          : Colors.red.shade50)
                                    : (saleEffect == -1
                                          ? Colors.red.shade50
                                          : Colors.orange.shade50),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                trackStock == 1
                                    ? "Stock: $qty"
                                    : (saleEffect == -1
                                          ? "Deduct"
                                          : "Non-stock"),
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: trackStock == 1
                                      ? (qty > 0
                                            ? Colors.blue.shade900
                                            : Colors.red)
                                      : (saleEffect == -1
                                            ? Colors.red.shade900
                                            : Colors.orange.shade900),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "${priceUnit.toStringAsFixed(0)} MMK / each",
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
        ],
      ),
    );
  }
}
