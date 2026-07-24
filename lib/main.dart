import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:nguwar/auth_service.dart';
import 'package:nguwar/login_screen.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:nguwar/splash_screen.dart';
import 'package:nguwar/transaction_history_page.dart';
import 'db_helper.dart';
import 'item_history_page.dart';
import 'sync_service.dart';
import 'dart:io';
import 'dart:async';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_saver/file_saver.dart';


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

  final SyncService _syncService = SyncService();

  String get _currentBranch => AuthService.currentUser?.branchId ?? 'nguwar_1';

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _quantityController = TextEditingController();
  final TextEditingController _priceController = TextEditingController();
  final TextEditingController _barcodeController = TextEditingController();
  final TextEditingController _checkoutScanController = TextEditingController();
  final TextEditingController _inventorySearchController =
      TextEditingController();
  final ScrollController _transactionLogsScrollController = ScrollController();

  static const int _transactionLogsPageSize = 50;

  final List<Map<String, dynamic>> _transactionLogs = [];

  bool _isTransactionLogsInitialLoading = true;
  bool _isTransactionLogsLoadingMore = false;
  bool _hasMoreTransactionLogs = true;

  int _transactionLogsOffset = 0;

  String _inventorySearchText = "";

  final FocusNode _checkoutScanFocusNode = FocusNode();
  final PageController _basketPageController = PageController();

  int _activeBasketIndex = 0;

  final List<List<Map<String, dynamic>>> _baskets = [
    <Map<String, dynamic>>[],
    <Map<String, dynamic>>[],
  ];

  List<Map<String, dynamic>> get _activeCart => _baskets[_activeBasketIndex];
  bool _hardwareScannerMode = false;
  bool _trackStock = true;
  int _saleEffect = 1;
  bool _isScanningCode = false;
  int _selectedIndex = 0;
  final FocusNode _nameFocusNode = FocusNode();
  bool _editUnlocked = false;
  bool _showInventoryPasswordBox = false;
  final TextEditingController _inventoryPasswordController =
      TextEditingController();

  static const String _inventoryEditPassword = "5408098";

  List<Map<String, Object?>> _inventoryItems = [];

  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;

  @override
  void initState() {
    super.initState();
    _loadInventoryItems();
    _syncService.startListening(branchId: _currentBranch);
    _syncService.syncPending(branchId: _currentBranch);
    _loadInitialTransactionLogs();

    _transactionLogsScrollController.addListener(() {
      if (!_transactionLogsScrollController.hasClients) return;

      if (_transactionLogsScrollController.position.pixels >=
          _transactionLogsScrollController.position.maxScrollExtent - 200) {
        _loadMoreTransactionLogs();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _syncService.syncPending(branchId: _currentBranch);
      final pulled = await _syncService.pullFromServer(
        branchId: _currentBranch,
      );
      if (pulled && mounted) {
        await _loadInventoryItems();
        setState(() {});
      }
    });
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) async {
      if (results.contains(ConnectivityResult.mobile) ||
          results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet)) {
        bool isOnline = await _checkInternetConnection();
        if (isOnline) {
          debugPrint("Network restored! Pushing pending data to server...");
          await _syncService.syncPending(branchId: _currentBranch);

          if (mounted) {
            await _loadInventoryItems();
          }
        }
      }
    });
  }

  Future<void> _loadInventoryItems() async {
    final items = await DBHelper.getItems();

    if (!mounted) return;

    setState(() {
      _inventoryItems = items;
    });
  }

  @override
  void dispose() {
    _syncService.dispose();
    _nameController.dispose();
    _quantityController.dispose();
    _priceController.dispose();
    _barcodeController.dispose();
    _checkoutScanController.dispose();
    _checkoutScanFocusNode.dispose();
    _nameFocusNode.dispose();
    _inventoryPasswordController.dispose();
    _inventorySearchController.dispose();
    _transactionLogsScrollController.dispose();
    _basketPageController.dispose();
    _connectivitySubscription.cancel();
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

  Future<void> _loadInitialTransactionLogs() async {
    if (!mounted) return;

    setState(() {
      _isTransactionLogsInitialLoading = true;
      _isTransactionLogsLoadingMore = false;
      _hasMoreTransactionLogs = true;
      _transactionLogsOffset = 0;
      _transactionLogs.clear();
    });

    try {
      final List<Map<String, dynamic>> firstPage =
          await DBHelper.getSalesPaginated(
            limit: _transactionLogsPageSize,
            offset: _transactionLogsOffset,
          );

      if (!mounted) return;

      setState(() {
        _transactionLogs.addAll(firstPage);
        _transactionLogsOffset += firstPage.length;
        _hasMoreTransactionLogs = firstPage.length == _transactionLogsPageSize;
        _isTransactionLogsInitialLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isTransactionLogsInitialLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to load transaction logs: $e")),
      );
    }
  }

  Future<void> _loadMoreTransactionLogs() async {
    if (_isTransactionLogsLoadingMore ||
        !_hasMoreTransactionLogs ||
        _isTransactionLogsInitialLoading) {
      return;
    }

    setState(() {
      _isTransactionLogsLoadingMore = true;
    });

    try {
      final List<Map<String, dynamic>> nextPage =
          await DBHelper.getSalesPaginated(
            limit: _transactionLogsPageSize,
            offset: _transactionLogsOffset,
          );

      if (!mounted) return;

      setState(() {
        _transactionLogs.addAll(nextPage);
        _transactionLogsOffset += nextPage.length;
        _hasMoreTransactionLogs = nextPage.length == _transactionLogsPageSize;
        _isTransactionLogsLoadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isTransactionLogsLoadingMore = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to load more transaction logs: $e")),
      );
    }
  }

  Map<String, List<Map<String, dynamic>>> _groupTransactionLogsByDate(
    List<Map<String, dynamic>> logs,
  ) {
    final Map<String, List<Map<String, dynamic>>> groupedLogs = {};

    for (final sale in logs) {
      final String rawDateStr = sale['saleDate']?.toString() ?? '';
      final String dateKey = rawDateStr.length >= 10
          ? rawDateStr.substring(0, 10)
          : "Unknown Date";

      groupedLogs.putIfAbsent(dateKey, () => []);
      groupedLogs[dateKey]!.add(sale);
    }

    return groupedLogs;
  }

  Widget _buildTransactionLogsBottomLoader() {
    if (_isTransactionLogsLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return const SizedBox(height: 16);
  }

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
      }, branchId: _currentBranch);
      await _loadInventoryItems();

      if (!mounted) return;

      _clearDrawerFields(resetTrackStock: true);
      Navigator.of(context).pop();

      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Colors.green.shade50,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Colors.green),
          ),
          title: const Row(
            children: [
              Icon(Icons.wifi, color: Colors.green),
              SizedBox(width: 8),
              Text("Online", style: TextStyle(color: Colors.green)),
            ],
          ),
          content: const Text(
            "Save Successfully. Don't forget to click refresh button.",
            style: TextStyle(color: Colors.black87),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text("OK", style: TextStyle(color: Colors.green)),
            ),
          ],
        ),
      );
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
          content: Text("Item not found for barcode: $barcode"),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 1),
        ),
      );
      return;
    }

    final int trackStock = (matchedItem['trackStock'] as num?)?.toInt() ?? 1;
    final int saleEffect = (matchedItem['saleEffect'] as num?)?.toInt() ?? 1;
    final String productName =
        matchedItem['name']?.toString() ?? "Unknown Item";
    final double unitPrice =
        (matchedItem['priceUnit'] as num?)?.toDouble() ?? 0.0;

    final int basketIndex = _activeCart.indexWhere(
      (element) => element['barcode'] == barcode,
    );

    if (basketIndex == -1 && _activeCart.length >= 20) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("⚠️ Basket is full! Maximum 20 unique items allowed."),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 3),
        ),
      );
      if (_hardwareScannerMode) {
        _requestHardwareScannerFocus();
      }
      return;
    }
    final int quantityInBasketAlready = basketIndex != -1
        ? (_activeCart[basketIndex]['quantity'] as num?)?.toInt() ?? 0
        : 0;

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
          "Added 1x $productName successfully! Total in basket: ${quantityInBasketAlready + 1}",
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
          // Allow negative stock
          final int absoluteNewStock = originalStock - purchaseQty;

          await DBHelper.updateItemQuantity(
            barcode,
            absoluteNewStock,
            branchId: _currentBranch,
          );
        }

        itemSummaries.add("${purchaseQty}x $name");
        orderGrandTotal += priceUnit * purchaseQty * saleEffect;
      }
    }

    await DBHelper.insertSale({
      'type': itemSummaries.join(", "),
      'price': orderGrandTotal,
      'saleDate': DateTime.now().toIso8601String(),
    }, branchId: _currentBranch);

    setState(() {
      _activeCart.clear();
    });
    await _syncService.syncPending(
      branchId: _currentBranch,
    ); // push new stock to server
    await _loadInventoryItems();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("🏁 Order confirmed!"),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Widget _buildTransactionLogsTab() {
    final Map<String, List<Map<String, dynamic>>> groupedLogs =
        _groupTransactionLogsByDate(_transactionLogs);

    final List<String> sortedDates = groupedLogs.keys.toList()
      ..sort((a, b) => b.compareTo(a));

    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        children: [
          GestureDetector(
            onTap: () {
              if (_editUnlocked) {
                Navigator.of(context)
                    .push(
                      MaterialPageRoute(
                        builder: (context) =>
                            TransactionHistoryPage(isUnlocked: _editUnlocked),
                      ),
                    )
                    .then((_) async {
                      await _loadInitialTransactionLogs();
                    });
                return;
              }
              showDialog(
                context: context,
                builder: (dialogCtx) => AlertDialog(
                  scrollable:
                      true, // Prevents bottom overflow when keyboard opens
                  title: const Row(
                    children: [
                      Icon(Icons.security, color: Color(0xFFFF6F00), size: 20),
                      SizedBox(width: 8),
                      Text(
                        "Admin Authentication",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: Color(0xFFFF6F00),
                        ),
                      ),
                    ],
                  ),
                  content: TextField(
                    controller: _inventoryPasswordController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(
                      letterSpacing: 4.0,
                      fontWeight: FontWeight.bold,
                    ),
                    decoration: InputDecoration(
                      hintText: "Enter PIN",
                      hintStyle: const TextStyle(
                        letterSpacing:
                            0, // Reset letter spacing for the hint text
                        fontWeight: FontWeight.normal,
                        color: Colors.grey,
                      ),
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      prefixIcon: const Icon(
                        Icons.lock_outline,
                        color: Colors.grey,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Colors.amber.shade600,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () {
                        _inventoryPasswordController.clear();
                        Navigator.of(dialogCtx).pop(); // Close dialog
                      },
                      child: const Text("Cancel"),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber.shade600,
                        foregroundColor: Colors.black87,
                      ),
                      onPressed: () {
                        // Check password
                        final String password = _inventoryPasswordController
                            .text
                            .trim();
                        if (password == _inventoryEditPassword) {
                          setState(() {
                            _editUnlocked = true;
                            _showInventoryPasswordBox = false;
                          });
                          _inventoryPasswordController.clear();
                          Navigator.of(dialogCtx).pop(); // Close dialog

                          // Navigate to history page after successful unlock
                          Navigator.of(context)
                              .push(
                                MaterialPageRoute(
                                  builder: (context) => TransactionHistoryPage(
                                    isUnlocked: _editUnlocked,
                                  ),
                                ),
                              )
                              .then((_) async {
                                await _loadInitialTransactionLogs();
                              });
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text("Wrong password"),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      },
                      child: const Text("Unlock"),
                    ),
                  ],
                ),
              );
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
                        fontSize: 16,
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

          const SizedBox(height: 10),

          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadInitialTransactionLogs,
              child: _isTransactionLogsInitialLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _transactionLogs.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(height: 100),
                        Center(
                          child: Text(
                            "No transaction history records discovered yet.",
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      controller: _transactionLogsScrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: sortedDates.length + 1,
                      itemBuilder: (context, dateIndex) {
                        if (dateIndex == sortedDates.length) {
                          return _buildTransactionLogsBottomLoader();
                        }

                        final String dateHeader = sortedDates[dateIndex];
                        final List<Map<String, dynamic>> dailySales =
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
                                  (saleRecord['price'] as num?)?.toDouble() ??
                                  0.0;

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
                                  trailing: Text(
                                    "${price.toStringAsFixed(0)} MMK",
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.green,
                                    ),
                                  ),
                                ),
                              );
                            }),
                          ],
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  double _getCartTotalCost() {
    return _getCartTotalCostFor(_activeCart);
  }

  double _getCartTotalCostFor(List<Map<String, dynamic>> cart) {
    return cart.fold(0.0, (sum, item) {
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
    _barcodeController.text = matched['barcode']?.toString() ?? '';

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

  void _checkInventoryPassword() {
    final String password = _inventoryPasswordController.text.trim();

    if (password == _inventoryEditPassword) {
      setState(() {
        _editUnlocked = true;
        _showInventoryPasswordBox = false;
        _inventoryPasswordController.clear();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("✅ Edit mode unlocked"),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("❌ Wrong password"),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _confirmDeleteItem(Map<String, Object?> item) async {
    final String barcode = item['barcode']?.toString() ?? '';
    final String name = item['name']?.toString() ?? 'Unknown Item';

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Delete Item"),
        content: Text("Are you sure you want to delete \"$name\"?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text("Cancel"),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.delete),
            label: const Text("Delete"),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await DBHelper.deleteItem(barcode, branchId: _currentBranch);

    await _syncService.syncPending(branchId: _currentBranch);

    await _loadInventoryItems();

    if (!mounted) return;

    setState(() {});

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.green.shade50,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Colors.green),
        ),
        title: const Row(
          children: [
            Icon(Icons.wifi, color: Colors.green),
            SizedBox(width: 8),
            Text("Delete Success", style: TextStyle(color: Colors.green)),
          ],
        ),
        content: const Text(
          "Deleted Successfully. Don't forget to click refresh button.",
          style: TextStyle(color: Colors.black87),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text("OK", style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
    );
  }
  // Make sure to import this

  Future<bool> _checkInternetConnection() async {
    try {
      final socket = await Socket.connect(
        '8.8.8.8',
        53,
        timeout: const Duration(seconds: 3),
      );
      socket
          .destroy(); // Close it immediately, we only wanted to test the connection
      return true;
    } on SocketException catch (_) {
      return false;
    } catch (_) {
      return false; // Catch any other timeout/connection errors
    }
  }

  Future<void> _showEditItemDialog(Map<String, Object?> item) async {
    final String barcode = item['barcode']?.toString() ?? '';

    final TextEditingController nameController = TextEditingController(
      text: item['name']?.toString() ?? '',
    );

    final TextEditingController quantityController = TextEditingController(
      text: ((item['quantity'] as num?)?.toInt() ?? 0).toString(),
    );

    final TextEditingController priceController = TextEditingController(
      text: ((item['priceUnit'] as num?)?.toDouble() ?? 0.0).toStringAsFixed(0),
    );

    bool trackStock = ((item['trackStock'] as num?)?.toInt() ?? 1) == 1;
    int saleEffect = (item['saleEffect'] as num?)?.toInt() ?? 1;

    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text("Edit Inventory Item"),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      enabled: false,
                      decoration: InputDecoration(
                        labelText: "Barcode",
                        border: const OutlineInputBorder(),
                        helperText: barcode,
                      ),
                    ),

                    const SizedBox(height: 14),

                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: "Product Name",
                        border: OutlineInputBorder(),
                      ),
                    ),

                    const SizedBox(height: 14),

                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text("Track Inventory Stock"),
                      value: trackStock,
                      onChanged: (value) {
                        setDialogState(() {
                          trackStock = value;
                        });
                      },
                    ),

                    if (trackStock) ...[
                      const SizedBox(height: 14),
                      TextField(
                        controller: quantityController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: "Quantity",
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],

                    if (!trackStock) ...[
                      const SizedBox(height: 14),
                      DropdownButtonFormField<int>(
                        value: saleEffect,
                        decoration: const InputDecoration(
                          labelText: "Non-stock behavior",
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 1, child: Text("Ice")),
                          DropdownMenuItem(
                            value: -1,
                            child: Text("Lottery cap"),
                          ),
                        ],
                        onChanged: (value) {
                          setDialogState(() {
                            saleEffect = value ?? 1;
                          });
                        },
                      ),
                    ],

                    const SizedBox(height: 14),

                    TextField(
                      controller: priceController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: "Unit Price",
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    FocusScope.of(dialogContext).unfocus(); // Safe unfocus
                    Navigator.of(dialogContext).pop(false);
                  },
                  child: const Text("Cancel"),
                ),
                ElevatedButton.icon(
                  onPressed: () async {
                    final String name = nameController.text.trim();
                    final int quantity =
                        int.tryParse(quantityController.text.trim()) ?? 0;
                    final double price =
                        double.tryParse(priceController.text.trim()) ?? 0.0;

                    if (name.isEmpty || price <= 0) {
                      if (!mounted) return;

                      ScaffoldMessenger.of(this.context).showSnackBar(
                        const SnackBar(
                          content: Text("⚠️ Name and valid price are required"),
                        ),
                      );
                      return;
                    }

                    try {
                      // Important: remove focus from TextField / Dropdown before closing dialog
                      FocusManager.instance.primaryFocus?.unfocus();

                      await DBHelper.updateItemOnly(
                        barcode: barcode,
                        name: name,
                        quantity: quantity,
                        priceUnit: price,
                        trackStock: trackStock ? 1 : 0,
                        saleEffect: trackStock ? 1 : saleEffect,
                        branchId: _currentBranch,
                      );

                      await Future.delayed(const Duration(milliseconds: 250));
                      if (dialogContext.mounted) {
                        Navigator.of(
                          dialogContext,
                        ).pop(true); // Don't use rootNavigator: true here
                      }
                    } catch (e) {
                      if (!mounted) return;

                      ScaffoldMessenger.of(this.context).showSnackBar(
                        SnackBar(
                          content: Text("❌ Update failed: $e"),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.save),
                  label: const Text("Update"),
                ),
              ],
            );
          },
        );
      },
    );

    if (!mounted) return;

    if (saved == true) {
      await _loadInventoryItems(); // ← refresh list
      await _syncService.syncPending(
        branchId: _currentBranch,
      ); // ← push to server

      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: Colors.green.shade50,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: Colors.green),
            ),
            title: const Row(
              children: [
                Icon(Icons.wifi, color: Colors.green),
                SizedBox(width: 8),
                Text("Update Success", style: TextStyle(color: Colors.green)),
              ],
            ),
            content: const Text(
              "Updated Successfully. Don't forget to click refresh button.",
              style: TextStyle(color: Colors.black87),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text("OK", style: TextStyle(color: Colors.green)),
              ),
            ],
          ),
        );
      });
    }
  }

  InputDecoration _customInputDecoration({
    required String label,
    required IconData icon,
    String? hint,
    String? helper,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
      prefixIcon: Icon(icon, color: Colors.amber.shade700),
      filled: true,
      fillColor: Colors.grey.shade50,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.amber, width: 2),
      ),
      floatingLabelStyle: const TextStyle(
        color: Colors.amber,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
        title: Text(
          _selectedIndex == 0
              ? "🛒 ${AuthService.currentUser?.shopName ?? 'Stock'}"
              : _selectedIndex == 1
              ? "📜 Transaction Logs"
              : "📦 Inventory",
        ),
        centerTitle: true,
        backgroundColor: Colors.amber,
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            color: Colors.black87,
            tooltip: 'Sync with Server',
            onPressed: () async {
              bool isOnline = await _checkInternetConnection();
              if (!isOnline) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("No internet connection."),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
                return;
              }
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Syncing with server...")),
                );
              }

              // 1. Push and Pull
              bool pushSuccess = await _syncService.syncPending(
                branchId: _currentBranch,
              );
              bool pullSuccess = await _syncService.pullFromServer(
                branchId: _currentBranch,
              );

              if (mounted) {
                String errorMessage = '';
                if (!pushSuccess) errorMessage += 'Push failed. ';
                if (!pullSuccess) errorMessage += 'Pull failed.';

                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      pushSuccess && pullSuccess
                          ? "Sync Complete"
                          : "Sync finished with errors: $errorMessage",
                    ),
                    backgroundColor: pushSuccess && pullSuccess
                        ? Colors.green
                        : Colors.orange,
                  ),
                );

                // 2. FORCE UI REFRESH
                final freshItems = await DBHelper.getItems();
                setState(() {
                  _inventoryItems = []; // clear first
                });

                await Future.delayed(
                  const Duration(milliseconds: 50),
                ); // let UI clear

                setState(() {
                  _inventoryItems = List.from(freshItems); // assign new
                });
              }
            },
          ),
          if (_selectedIndex == 0) ...[
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
          if (_selectedIndex == 2) ...[
            IconButton(
              tooltip: _editUnlocked ? "Lock edit mode" : "Unlock edit mode",
              icon: Icon(
                _editUnlocked ? Icons.lock_open : Icons.lock,
                color: _editUnlocked ? Colors.green.shade900 : Colors.black87,
              ),
              onPressed: () {
                if (_editUnlocked) {
                  setState(() {
                    _editUnlocked = false;
                    _showInventoryPasswordBox = false;
                    _inventoryPasswordController.clear();
                  });

                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("🔒 Edit mode locked")),
                  );
                } else {
                  setState(() {
                    _showInventoryPasswordBox = !_showInventoryPasswordBox;
                  });
                }
              },
            ),
            const SizedBox(width: 8),
          ],
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
                    Text("Add New Item", style: TextStyle(fontSize: 20)),
                  ],
                ),
                const Divider(height: 30),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    "Track Inventory Stock",
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    _trackStock
                        ? "This item reduces store stock"
                        : "This item is sellable but not stock-tracked",
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),
                  value: _trackStock,
                  activeColor: Colors.amber,
                  onChanged: (value) {
                    setState(() {
                      _trackStock = value;
                      _clearDrawerFields();
                    });
                  },
                ),
                const SizedBox(height: 8),
                if (!_trackStock) ...[
                  DropdownButtonFormField<int>(
                    value: _saleEffect,
                    decoration: _customInputDecoration(
                      label: "Non-stock behavior",
                      icon: Icons.category_rounded,
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
                        decoration: _customInputDecoration(
                          label: "Barcode (ID)",
                          icon: Icons.qr_code_scanner_rounded,
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
                    Container(
                      height: 56, // Match the height of the modern text field
                      decoration: BoxDecoration(
                        color: Colors.amber.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.amber.shade200),
                      ),
                      child: IconButton(
                        onPressed: () {
                          showDialog(
                            context: context,

                            builder: (dialogCtx) {
                              return AlertDialog(
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
                                            await DBHelper.getItemByBarcode(
                                              code,
                                            );

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
                              );
                            },
                          );
                        },
                        icon: const Icon(Icons.camera_alt, color: Colors.amber),
                        tooltip: "Scan Barcode",
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                RawAutocomplete<Map<String, Object?>>(
                  textEditingController: _nameController,
                  focusNode: _nameFocusNode,

                  displayStringForOption: (item) {
                    return item['name']?.toString() ?? '';
                  },

                  optionsBuilder: (TextEditingValue textEditingValue) {
                    final keyword = textEditingValue.text.trim().toLowerCase();

                    if (keyword.isEmpty) {
                      return const Iterable<Map<String, Object?>>.empty();
                    }

                    return _inventoryItems
                        .where((item) {
                          final name =
                              item['name']?.toString().toLowerCase() ?? '';
                          return name.contains(keyword);
                        })
                        .take(10);
                  },

                  onSelected: (item) {
                    setState(() {
                      _fillDrawerWithMatchedItem(item);
                    });

                    _nameFocusNode.unfocus();
                  },

                  fieldViewBuilder:
                      (
                        BuildContext context,
                        TextEditingController controller,
                        FocusNode focusNode,
                        VoidCallback onFieldSubmitted,
                      ) {
                        return TextField(
                          controller: controller,
                          focusNode: focusNode,
                          decoration: _customInputDecoration(
                            label: "Product Name",
                            icon: Icons.shopping_bag_rounded,
                            hint: "Search from inventory",
                          ),
                        );
                      },

                  optionsViewBuilder:
                      (
                        BuildContext context,
                        AutocompleteOnSelected<Map<String, Object?>> onSelected,
                        Iterable<Map<String, Object?>> options,
                      ) {
                        return Align(
                          alignment: Alignment.topLeft,
                          child: Material(
                            elevation: 8,
                            borderRadius: BorderRadius.circular(12),
                            clipBehavior: Clip.antiAlias,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxHeight: 250,
                                maxWidth: 320,
                              ),
                              child: ListView.builder(
                                padding: EdgeInsets.zero,
                                shrinkWrap: true,
                                itemCount: options.length,
                                itemBuilder: (context, index) {
                                  final item = options.elementAt(index);

                                  final name = item['name']?.toString() ?? '';
                                  final barcode =
                                      item['barcode']?.toString() ?? '';
                                  final quantity =
                                      item['quantity']?.toString() ?? '0';
                                  final price =
                                      item['priceUnit']?.toString() ?? '0';

                                  return ListTile(
                                    dense: true,
                                    leading: const Icon(
                                      Icons.inventory_2_outlined,
                                      size: 20,
                                    ),
                                    title: Text(
                                      name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    subtitle: Text(
                                      "ID: $barcode • Qty: $quantity • Price: $price",
                                      style: TextStyle(
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                    onTap: () {
                                      onSelected(item);
                                    },
                                  );
                                },
                              ),
                            ),
                          ),
                        );
                      },
                ),
                const SizedBox(height: 16),
                if (_trackStock) ...[
                  TextField(
                    controller: _quantityController,
                    keyboardType: TextInputType.number,
                    decoration: _customInputDecoration(
                      label: "Quantity Stock",
                      icon: Icons.layers_rounded,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: _priceController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: _customInputDecoration(
                    label: "Unit Price",
                    icon: Icons.payments_rounded,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      bool isOnline = await _checkInternetConnection();

                      if (!mounted) return;
                      if (!isOnline) {
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: Colors.red.shade50,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: const BorderSide(color: Colors.red),
                            ),
                            title: const Row(
                              children: [
                                Icon(Icons.wifi_off, color: Colors.red),
                                SizedBox(width: 8),
                                Text(
                                  "Offline",
                                  style: TextStyle(color: Colors.red),
                                ),
                              ],
                            ),
                            content: const Text(
                              "No internet connection. Please check your network and try again.",
                              style: TextStyle(color: Colors.black87),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                child: const Text(
                                  "OK",
                                  style: TextStyle(color: Colors.red),
                                ),
                              ),
                            ],
                          ),
                        );
                        return; // Prevent saving
                      }
                      await _saveItemFromDrawer();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amber,
                      foregroundColor: Colors.black87,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.save_rounded),
                    label: const Text("Save", style: TextStyle(fontSize: 16)),
                  ),
                ),

                // ── PROFILE SECTION ──
                const SizedBox(height: 16),
                const Divider(height: 20),
                GestureDetector(
                  onTap: () {
                    Navigator.of(context)
                        .push(
                          MaterialPageRoute(
                            builder: (context) => const ItemHistoryPage(),
                          ),
                        )
                        .then((_) => setState(() {}));
                  },
                  child: Container(
                    width: double.infinity, // ✅ constrain width
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
                const Divider(height: 20),
                // Shop profile card
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.amber.shade200),
                  ),
                  child: Row(
                    children: [
                      const CircleAvatar(
                        backgroundColor: Colors.amber,
                        radius: 24,
                        child: Icon(Icons.store, color: Colors.white, size: 24),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              AuthService.currentShopName ?? 'My Shop',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '@${AuthService.currentUsername ?? ''}',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),

                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      // Close the drawer first
                      Navigator.of(context).pop();
                      await DBHelper.clearLocalData();
                      // Log out
                      await AuthService.logout();
                      if (context.mounted) {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                const LoginScreen(), // ← canPop: true
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.switch_account, color: Colors.amber),
                    label: const Text(
                      'Switch Account',
                      style: TextStyle(color: Colors.black),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.amber),
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
        children: [
          _buildHomeTab(),
          _buildTransactionLogsTab(),
          _buildInventoryTab(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        type: BottomNavigationBarType.fixed,
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
            icon: Icon(Icons.receipt_long),
            label: "Logs",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.inventory_2),
            label: "Inventory",
          ),
        ],
      ),
    );
  }

  void _increaseCartQty(int index) {
    setState(() {
      final item = Map<String, Object?>.from(_activeCart[index]);
      final int currentQty = (item['quantity'] as num?)?.toInt() ?? 0;

      item['quantity'] = currentQty + 1;
      _activeCart[index] = item;
    });
  }

  void _decreaseCartQty(int index) {
    setState(() {
      final item = Map<String, Object?>.from(_activeCart[index]);
      final int currentQty = (item['quantity'] as num?)?.toInt() ?? 0;

      if (currentQty <= 1) {
        _activeCart.removeAt(index);
      } else {
        item['quantity'] = currentQty - 1;
        _activeCart[index] = item;
      }
    });
  }

  void _removeCartItem(int index) {
    setState(() {
      _activeCart.removeAt(index);
    });
  }

  Widget _cartIconButton({
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 22),
      color: color,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      visualDensity: VisualDensity.compact,
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
          Row(
            children: [
              Expanded(
                child: Text(
                  "🛒 Basket ${_activeBasketIndex + 1}",
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                "Swipe ⇆",
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          Row(
            children: List.generate(_baskets.length, (index) {
              final bool selected = index == _activeBasketIndex;
              final int itemCount = _baskets[index].fold<int>(
                0,
                (sum, item) => sum + ((item['quantity'] as num?)?.toInt() ?? 0),
              );

              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: ChoiceChip(
                    selected: selected,
                    label: Text("Basket ${index + 1} • $itemCount"),
                    selectedColor: Colors.amber.shade300,
                    onSelected: (_) {
                      setState(() {
                        _activeBasketIndex = index;
                      });

                      _basketPageController.animateToPage(
                        index,
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                      );
                    },
                  ),
                ),
              );
            }),
          ),

          const SizedBox(height: 6),
          Expanded(
            flex: 3,
            child: PageView.builder(
              controller: _basketPageController,
              itemCount: _baskets.length,
              onPageChanged: (index) {
                setState(() {
                  _activeBasketIndex = index;
                });

                if (_hardwareScannerMode) {
                  _requestHardwareScannerFocus();
                }
              },
              itemBuilder: (context, basketIndex) {
                final cart = _baskets[basketIndex];

                return cart.isEmpty
                    ? Card(
                        child: Center(
                          child: Text(
                            "Basket ${basketIndex + 1} is empty.\nScan with hardware scanner or tap the camera icon!",
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : Card(
                        color: Colors.white,
                        child: ListView.builder(
                          itemCount: cart.length,
                          itemBuilder: (context, index) {
                            final cartItem = cart[index];
                            final int saleEffect =
                                (cartItem['saleEffect'] as num?)?.toInt() ?? 1;
                            final double unitPrice =
                                (cartItem['priceUnit'] as num?)?.toDouble() ??
                                0.0;
                            final int qty =
                                (cartItem['quantity'] as num?)?.toInt() ?? 0;
                            final String name =
                                cartItem['name']?.toString() ?? 'Unknown Item';

                            final double totalItemCost =
                                unitPrice * qty * saleEffect;

                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.08),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        CircleAvatar(
                                          radius: 24,
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

                                        const SizedBox(width: 12),

                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              const SizedBox(height: 3),
                                              Text(
                                                saleEffect == -1
                                                    ? "Deduct item: ${unitPrice.toStringAsFixed(0)} MMK"
                                                    : "Unit Price: ${unitPrice.toStringAsFixed(0)} MMK",
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                  color: Colors.black54,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),

                                    const SizedBox(height: 8),

                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            "${totalItemCost.toStringAsFixed(0)} MMK",
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: saleEffect == -1
                                                  ? Colors.red
                                                  : Colors.green,
                                            ),
                                          ),
                                        ),

                                        _cartIconButton(
                                          icon: Icons.remove_circle_outline,
                                          color: Colors.orange,
                                          onPressed: () =>
                                              _decreaseCartQty(index),
                                        ),

                                        _cartIconButton(
                                          icon: Icons.add_circle_outline,
                                          color: Colors.green,
                                          onPressed: () =>
                                              _increaseCartQty(index),
                                        ),

                                        _cartIconButton(
                                          icon: Icons.delete,
                                          color: Colors.red,
                                          onPressed: () =>
                                              _removeCartItem(index),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      );
              },
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
        ],
      ),
    );
  }

  Widget _buildInventoryTab() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "📦 Inventory",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                ElevatedButton.icon(
                  onPressed: _exportInventoryToCSV,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber.shade300,
                    foregroundColor: Colors.white,
                    elevation: 1,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.download, size: 16),
                  label: const Text(
                    "Export Excel",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),
            TextField(
              controller: _inventorySearchController,
              decoration: InputDecoration(
                hintText: "Search by product name or barcode...",
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _inventorySearchText.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _inventorySearchController.clear();
                          setState(() => _inventorySearchText = "");
                        },
                      )
                    : null,
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (value) => setState(
                () => _inventorySearchText = value.trim().toLowerCase(),
              ),
            ),
            const SizedBox(height: 10),
            if (_showInventoryPasswordBox && !_editUnlocked) ...[
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: Colors.amber.shade300, width: 1.5),
                ),
                color: Colors.amber.shade50,
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 1. Header Row
                      Row(
                        children: [
                          Icon(
                            Icons.security,
                            color: Colors.amber.shade900,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            "Admin Authentication",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: Colors.amber.shade900,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // 2. Modern TextField
                      TextField(
                        controller: _inventoryPasswordController,
                        obscureText: true,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(
                          letterSpacing: 4.0, // Spreads out the dots nicely
                          fontWeight: FontWeight.bold,
                        ),
                        decoration: InputDecoration(
                          hintText: "Enter PIN",
                          hintStyle: const TextStyle(
                            letterSpacing:
                                0, // Reset letter spacing for the hint text
                            fontWeight: FontWeight.normal,
                            color: Colors.grey,
                          ),
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          prefixIcon: const Icon(
                            Icons.lock_outline,
                            color: Colors.grey,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: Colors.amber.shade600,
                              width: 2,
                            ),
                          ),
                        ),
                        onSubmitted: (_) => _checkInventoryPassword(),
                      ),
                      const SizedBox(height: 16),

                      // 3. Styled Buttons
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.grey.shade700,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              onPressed: () {
                                setState(() {
                                  _showInventoryPasswordBox = false;
                                  _inventoryPasswordController.clear();
                                });
                              },
                              child: const Text(
                                "Cancel",
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.amber.shade600,
                                foregroundColor: Colors.black87,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              onPressed: _checkInventoryPassword,
                              icon: const Icon(Icons.lock_open, size: 18),
                              label: const Text(
                                "Unlock",
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  await _syncService.syncPending(branchId: _currentBranch);
                  await _syncService.pullFromServer(branchId: _currentBranch);
                  final freshItems = await DBHelper.getItems();
                  setState(() {
                    _inventoryItems = List.from(freshItems);
                  });
                  await _loadInventoryItems();
                  setState(() {}); // Updates the tab instantly
                },
                child: _inventoryItems.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          SizedBox(height: 100),
                          Center(
                            child: Text(
                              "No products stored in database. Add them in the drawer.",
                            ),
                          ),
                        ],
                      )
                    : Builder(
                        builder: (_) {
                          final storeItems = _inventoryItems.where((item) {
                            final name =
                                item['name']?.toString().toLowerCase() ?? '';
                            final barcode =
                                item['barcode']?.toString().toLowerCase() ?? '';
                            return name.contains(_inventorySearchText) ||
                                barcode.contains(_inventorySearchText);
                          }).toList();

                          if (storeItems.isEmpty) {
                            return ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: const [
                                SizedBox(height: 100),
                                Center(
                                  child: Text(
                                    "No matching products found.",
                                    style: TextStyle(color: Colors.grey),
                                  ),
                                ),
                              ],
                            );
                          }

                          return ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            itemCount: storeItems.length,
                            itemBuilder: (context, index) {
                              final item = storeItems[index];

                              final int trackStock =
                                  (item['trackStock'] as num?)?.toInt() ?? 1;
                              final int qty =
                                  (item['quantity'] as num?)?.toInt() ?? 0;
                              final int saleEffect =
                                  (item['saleEffect'] as num?)?.toInt() ?? 1;
                              final double priceUnit =
                                  double.tryParse(
                                    item['priceUnit']?.toString() ?? '0',
                                  ) ??
                                  0.0;
                              final String name =
                                  item['name']?.toString() ?? 'Unknown Item';
                              final String barcode =
                                  item['barcode']?.toString() ?? '-';

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
                                  trailing: _editUnlocked
                                      ? Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              tooltip: "Edit",
                                              icon: const Icon(
                                                Icons.edit,
                                                color: Colors.blue,
                                              ),
                                              onPressed: () =>
                                                  _showEditItemDialog(item),
                                            ),
                                            IconButton(
                                              tooltip: "Delete",
                                              icon: const Icon(
                                                Icons.delete,
                                                color: Colors.red,
                                              ),
                                              onPressed: () =>
                                                  _confirmDeleteItem(item),
                                            ),
                                          ],
                                        )
                                      : Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
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
                                                          : Colors
                                                                .orange
                                                                .shade50),
                                                borderRadius:
                                                    BorderRadius.circular(8),
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
                                                            ? Colors
                                                                  .blue
                                                                  .shade900
                                                            : Colors.red)
                                                      : (saleEffect == -1
                                                            ? Colors
                                                                  .red
                                                                  .shade900
                                                            : Colors
                                                                  .orange
                                                                  .shade900),
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
            ),
          ],
        ),
      ),
    );
  }

   Future<void> _exportInventoryToCSV() async {
    try {
      if (_inventoryItems.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("No items to export.")),
        );
        return;
      }

      // 1. Create the CSV header row
      List<List<dynamic>> rows = [
        [
          "Barcode ID",
          "Product Name",
          "Stock Quantity",
          "Unit Price (MMK)",
          "Stock Tracked",
          "Sale Effect",
        ],
      ];

      // 2. Add data rows
      for (final item in _inventoryItems) {
        final trackStock = (item['trackStock'] as num?)?.toInt() == 1 ? 'Yes' : 'No';
        final saleEffect = (item['saleEffect'] as num?)?.toInt() == -1 ? 'Deduct' : 'Normal';
        
        final double price = (item['priceUnit'] as num?)?.toDouble() ?? 0.0;

        rows.add([
          item['barcode']?.toString() ?? '',
          item['name']?.toString() ?? '',
          (item['quantity'] as num?)?.toInt() ?? 0,
          price , // Hide price if locked
          trackStock,
          saleEffect,
        ]);
      }

      // 3. Convert to CSV string
      String csvData = const ListToCsvConverter().convert(rows);

      // 4. Save to temporary file for sharing
      final directory = await getTemporaryDirectory();
      final String fileName = 'inventory_export_${DateTime.now().millisecondsSinceEpoch}';
      final String filePath = '${directory.path}/$fileName.csv';
      final File tempFile = File(filePath);
      await tempFile.writeAsString(csvData);

      if (!mounted) return;

      // 5. Ask User: Share or Download?
      showDialog(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.file_present, color: Colors.amber),
              SizedBox(width: 8),
              Text("Export Inventory"),
            ],
          ),
          content: const Text("How would you like to export this data?"),
          actionsAlignment: MainAxisAlignment.spaceEvenly,
          actions: [
            // --- OPTION 1: SHARE ---
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.blue,
                side: const BorderSide(color: Colors.blue),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              onPressed: () async {
                Navigator.of(dialogCtx).pop(); // Close dialog first
                
                final result = await Share.shareXFiles([
                  XFile(filePath),
                ], text: 'Inventory Export');

                if (result.status == ShareResultStatus.success && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Shared successfully!")),
                  );
                }
              },
              icon: const Icon(Icons.share, size: 18),
              label: const Text("Share File"),
            ),

                     // --- OPTION 2: DOWNLOAD TO PHONE ---
                     // --- OPTION 2: DOWNLOAD TO PHONE ---
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber.shade600,
                foregroundColor: Colors.black87,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              onPressed: () async {
                Navigator.of(dialogCtx).pop(); // Close dialog first

                try {
                  // CHANGED: Added the ext parameter as required by saveAs
                  final resultPath = await FileSaver.instance.saveAs(
                    name: fileName, // Use the base name, no .csv here
                    bytes: await tempFile.readAsBytes(),
                    fileExtension: 'csv', // Pass the extension here
                    mimeType: MimeType.csv,
                  );

                  // If resultPath is null, the user cancelled the save dialog.
                  if (resultPath != null && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text("✅ Saved successfully! Check your Files app."),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                } catch (saveError) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("Save failed: $saveError"), backgroundColor: Colors.red),
                    );
                  }
                }
              },
              icon: const Icon(Icons.download, size: 18),
              label: const Text("Save to Phone"),
            ),
          ],
        ),
      );

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Export failed: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
