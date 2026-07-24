import 'package:flutter/material.dart';
import 'db_helper.dart';

class TransactionHistoryPage extends StatefulWidget {
  final bool isUnlocked;

  const TransactionHistoryPage({super.key, required this.isUnlocked});

  @override
  State<TransactionHistoryPage> createState() => _TransactionHistoryPageState();
}

class _TransactionHistoryPageState extends State<TransactionHistoryPage> {
  final GlobalKey<RefreshIndicatorState> _refreshKey =
      GlobalKey<RefreshIndicatorState>();

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _soldItemSearchController =
      TextEditingController();

  static const int _datePageSize = 3;

  final List<Map<String, dynamic>> _dateSummaries = [];
  final Map<String, List<Map<String, dynamic>>> _salesByDate = {};

  bool _showDailyItemTotals = false;
  bool _isInitialLoading = true;
  bool _isLoadingMore = false;
  bool _hasMoreData = true;

  int _dateOffset = 0;

  DateTime? _selectedFilterDate;
  String? _selectedFilterDateText;

  String _soldItemSearchText = '';

  @override
  void initState() {
    super.initState();

    _loadInitialSales();

    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;

      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 200) {
        _loadMoreSales();
      }
    });
  }

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0.0;
  }

  Future<void> _loadInitialSales() async {
    setState(() {
      _isInitialLoading = true;
      _isLoadingMore = false;
      _hasMoreData = true;
      _dateOffset = 0;
      _dateSummaries.clear();
      _salesByDate.clear();
    });

    try {
      if (_selectedFilterDateText != null) {
        final summary = await DBHelper.getSaleDateSummary(
          _selectedFilterDateText!,
        );

        if (summary == null) {
          if (!mounted) return;

          setState(() {
            _hasMoreData = false;
            _isInitialLoading = false;
          });

          return;
        }

        final sales = await DBHelper.getSalesByDate(_selectedFilterDateText!);

        if (!mounted) return;

        setState(() {
          _dateSummaries.add(summary);
          _salesByDate[_selectedFilterDateText!] = sales;
          _hasMoreData = false;
          _isInitialLoading = false;
        });

        return;
      }

      final summaries = await DBHelper.getSaleDateSummariesPaginated(
        limit: _datePageSize,
        offset: _dateOffset,
      );

      final Map<String, List<Map<String, dynamic>>> loadedSales = {};

      for (final summary in summaries) {
        final String dateKey = summary['dateKey']?.toString() ?? '';
        if (dateKey.isEmpty) continue;

        loadedSales[dateKey] = await DBHelper.getSalesByDate(dateKey);
      }

      if (!mounted) return;

      setState(() {
        _dateSummaries.addAll(summaries);
        _salesByDate.addAll(loadedSales);
        _dateOffset += summaries.length;
        _hasMoreData = summaries.length == _datePageSize;
        _isInitialLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isInitialLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to load transactions: $e")),
      );
    }
  }

  Future<void> _loadMoreSales() async {
    if (_isLoadingMore || !_hasMoreData || _isInitialLoading) return;

    // If one date is selected, all transactions for that date are already loaded.
    if (_selectedFilterDateText != null) return;

    setState(() {
      _isLoadingMore = true;
    });

    try {
      final summaries = await DBHelper.getSaleDateSummariesPaginated(
        limit: _datePageSize,
        offset: _dateOffset,
      );

      final Map<String, List<Map<String, dynamic>>> loadedSales = {};

      for (final summary in summaries) {
        final String dateKey = summary['dateKey']?.toString() ?? '';
        if (dateKey.isEmpty) continue;

        loadedSales[dateKey] = await DBHelper.getSalesByDate(dateKey);
      }

      if (!mounted) return;

      setState(() {
        _dateSummaries.addAll(summaries);
        _salesByDate.addAll(loadedSales);
        _dateOffset += summaries.length;
        _hasMoreData = summaries.length == _datePageSize;
        _isLoadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isLoadingMore = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to load more transactions: $e")),
      );
    }
  }

  Future<void> _pickFilterDate() async {
    final DateTime now = DateTime.now();

    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedFilterDate ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      helpText: 'Select transaction date',
    );

    if (picked == null) return;

    final String formatted =
        "${picked.year.toString().padLeft(4, '0')}-"
        "${picked.month.toString().padLeft(2, '0')}-"
        "${picked.day.toString().padLeft(2, '0')}";

    setState(() {
      _selectedFilterDate = picked;
      _selectedFilterDateText = formatted;
    });

    await _loadInitialSales();
  }

  Future<void> _clearFilterDate() async {
    setState(() {
      _selectedFilterDate = null;
      _selectedFilterDateText = null;
    });

    await _loadInitialSales();
  }

  void _clearSoldItemSearch() {
    setState(() {
      _soldItemSearchText = '';
      _soldItemSearchController.clear();
    });
  }

  Map<String, int> _buildItemTotalsForSales(
    List<Map<String, dynamic>> dailySales,
  ) {
    final Map<String, int> result = {};

    for (final sale in dailySales) {
      final String typeText = sale['type']?.toString() ?? '';
      final List<String> parts = typeText.split(',');

      for (final rawPart in parts) {
        final String part = rawPart.trim();

        final match = RegExp(r'^(\d+)x\s+(.+)$').firstMatch(part);
        if (match != null) {
          final int qty = int.tryParse(match.group(1) ?? '0') ?? 0;
          final String itemName = match.group(2)?.trim() ?? 'Unknown Item';

          result[itemName] = (result[itemName] ?? 0) + qty;
        }
      }
    }

    return result;
  }

  List<MapEntry<String, int>> _filterSoldItemEntries(
    Map<String, int> itemTotals,
  ) {
    final String keyword = _soldItemSearchText.trim().toLowerCase();

    final List<MapEntry<String, int>> entries = itemTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    if (keyword.isEmpty) return entries;

    return entries.where((entry) {
      return entry.key.toLowerCase().contains(keyword);
    }).toList();
  }

  Widget _buildSoldItemSearchBox() {
    if (!_showDailyItemTotals) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextField(
        controller: _soldItemSearchController,
        decoration: InputDecoration(
          hintText: _selectedFilterDateText == null
              ? "Search sold item in loaded days"
              : "Search sold item on $_selectedFilterDateText",
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _soldItemSearchText.trim().isEmpty
              ? null
              : IconButton(
                  onPressed: _clearSoldItemSearch,
                  icon: const Icon(Icons.close),
                ),
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
        onChanged: (value) {
          setState(() {
            _soldItemSearchText = value;
          });
        },
      ),
    );
  }

  Widget _buildBottomLoader() {
    if (_isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (!_hasMoreData && _dateSummaries.isNotEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            "No more transaction records.",
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildDateHeader({
    required String dateHeader,
    required double dailyAmount,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "📅 $dateHeader",
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.orange.shade900,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              "Total: ${dailyAmount.toStringAsFixed(0)} MMK",
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.green.shade800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDailyItemTotalsView() {
    return ListView.builder(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _dateSummaries.length + 1,
      itemBuilder: (context, dateIndex) {
        if (dateIndex == _dateSummaries.length) {
          return _buildBottomLoader();
        }

        final summary = _dateSummaries[dateIndex];
        final String dateHeader =
            summary['dateKey']?.toString() ?? 'Unknown Date';

        final List<Map<String, dynamic>> dailySales =
            _salesByDate[dateHeader] ?? [];

        final Map<String, int> itemTotals = _buildItemTotalsForSales(
          dailySales,
        );

        final List<MapEntry<String, int>> entries = _filterSoldItemEntries(
          itemTotals,
        );

        final double dailyAmount = _toDouble(summary['totalAmount']);

        final bool isSearching = _soldItemSearchText.trim().isNotEmpty;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDateHeader(
              dateHeader: dateHeader,
              dailyAmount: dailyAmount,
              color: Colors.orange.shade100,
            ),

            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 4),
                child: Text(
                  isSearching
                      ? "No sold item matched '${_soldItemSearchText.trim()}' on this day."
                      : "No item total details.",
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              )
            else
              ...entries.map((entry) {
                return Card(
                  color: Colors.white,
                  elevation: 0.5,
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    dense: true,
                    leading: const Icon(
                      Icons.inventory_2,
                      color: Colors.orange,
                    ),
                    title: Text(
                      entry.key,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    trailing: Text(
                      "${entry.value} pcs",
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.deepOrange,
                      ),
                    ),
                  ),
                );
              }),
          ],
        );
      },
    );
  }

  Widget _buildFullArchiveView() {
    return ListView.builder(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _dateSummaries.length + 1,
      itemBuilder: (context, dateIndex) {
        if (dateIndex == _dateSummaries.length) {
          return _buildBottomLoader();
        }

        final summary = _dateSummaries[dateIndex];
        final String dateHeader =
            summary['dateKey']?.toString() ?? 'Unknown Date';

        final List<Map<String, dynamic>> dailySales =
            _salesByDate[dateHeader] ?? [];

        final double dailyAmount = _toDouble(summary['totalAmount']);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDateHeader(
              dateHeader: dateHeader,
              dailyAmount: dailyAmount,
              color: Colors.grey.shade300,
            ),

            ...dailySales.map((saleRecord) {
              final String rawSaleDate =
                  saleRecord['saleDate']?.toString() ?? '';

              final String timeDisplay = rawSaleDate.length >= 16
                  ? rawSaleDate.substring(11, 16)
                  : "00:00";

              final double price = _toDouble(saleRecord['price']);

              return Card(
                color: Colors.white,
                elevation: 0.5,
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.receipt_long, color: Colors.green),
                  title: Text(
                    "${saleRecord['type']}",
                    style: const TextStyle(fontWeight: FontWeight.w500),
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
    );
  }

  String _emptyMessage() {
    if (_selectedFilterDateText != null) {
      return "No transactions found on $_selectedFilterDateText";
    }

    return "No transaction history records discovered yet.";
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _soldItemSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool hasDateFilter = _selectedFilterDateText != null;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F6F6),
      appBar: AppBar(
        title: const Text("Transaction History"),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.amber,
        actions: [
          IconButton(
            tooltip: "Search by date",
            onPressed: _pickFilterDate,
            icon: const Icon(Icons.calendar_month),
          ),
          if (hasDateFilter)
            IconButton(
              tooltip: "Clear date filter",
              onPressed: _clearFilterDate,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      _showDailyItemTotals
                          ? "📦 Daily Item Totals"
                          : "📜 Full Archive Sorted by Day",
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    "Item Totals",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey,
                    ),
                  ),
                  Switch(
                    value: _showDailyItemTotals,
                    onChanged: (value) {
                      setState(() {
                        _showDailyItemTotals = value;

                        if (!value) {
                          _soldItemSearchText = '';
                          _soldItemSearchController.clear();
                        }
                      });
                    },
                  ),
                ],
              ),

              if (_selectedFilterDateText != null) ...[
                const SizedBox(height: 6),
                Text(
                  "Filtered date: $_selectedFilterDateText",
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.deepOrange,
                  ),
                ),
              ],

              _buildSoldItemSearchBox(),

              const SizedBox(height: 12),

              Expanded(
                child: RefreshIndicator(
                  key: _refreshKey,
                  onRefresh: _loadInitialSales,
                  child: _isInitialLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _dateSummaries.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            const SizedBox(height: 100),
                            Center(
                              child: Text(
                                _emptyMessage(),
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.grey),
                              ),
                            ),
                          ],
                        )
                      : _showDailyItemTotals
                      ? _buildDailyItemTotalsView()
                      : _buildFullArchiveView(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
