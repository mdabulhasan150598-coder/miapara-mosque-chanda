import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MiaparaChandaApp());
}

// বাংলা সংখ্যা রূপান্তর হেল্পার
class BanglaHelper {
  static const Map<String, String> _bnDigits = {
    '0': '০', '1': '১', '2': '২', '3': '৩', '4': '৪',
    '5': '৫', '6': '৬', '7': '৭', '8': '৮', '9': '৯',
  };

  static const List<String> months = [
    '', 'জানুয়ারি', 'ফেব্রুয়ারি', 'মার্চ', 'এপ্রিল', 'মে', 'জুন',
    'জুলাই', 'আগস্ট', 'সেপ্টেম্বর', 'অক্টোবর', 'নভেম্বর', 'ডিসেম্বর'
  ];

  static String toBn(dynamic n) {
    if (n == null) return '০';
    return n.toString().split('').map((c) => _bnDigits[c] ?? c).join('');
  }

  static String formatTaka(int paisa) {
    return '৳ ${toBn(paisa ~/ 100)}';
  }
}

class MiaparaChandaApp extends StatelessWidget {
  const MiaparaChandaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'মিয়াপাড়া কেন্দ্রীয় জামে মসজিদ',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.teal,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF4F6F6),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Database? _db;
  int _curYear = DateTime.now().year;
  int _curMonth = DateTime.now().month;
  List<Map<String, dynamic>> _memberList = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initDBAndLoad();
  }

  Future<void> _initDBAndLoad() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'miapara_chanda_simple.db');

    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE members (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            phone TEXT,
            monthly_rate INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE collections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            member_id INTEGER,
            year INTEGER,
            month INTEGER,
            amount INTEGER,
            date TEXT
          )
        ''');
      },
    );
    _loadData();
  }

  Future<void> _loadData() async {
    if (_db == null) return;
    setState(() => _isLoading = true);

    final members = await _db!.query('members', orderBy: 'id ASC');
    List<Map<String, dynamic>> data = [];

    for (var m in members) {
      final mId = m['id'] as int;
      final rate = m['monthly_rate'] as int;

      final res = await _db!.rawQuery('''
        SELECT COALESCE(SUM(amount), 0) as paid 
        FROM collections 
        WHERE member_id = ? AND year = ? AND month = ?
      ''', [mId, _curYear, _curMonth]);

      final paid = res.first['paid'] as int;
      final due = rate > paid ? rate - paid : 0;

      data.add({
        'id': mId,
        'name': m['name'],
        'phone': m['phone'],
        'rate': rate,
        'paid': paid,
        'due': due,
      });
    }

    setState(() {
      _memberList = data;
      _isLoading = false;
    });
  }

  void _addMember() {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final rateCtrl = TextEditingController(text: '200');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('নতুন সদস্য যোগ করুন'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'সদস্যের নাম')),
            TextField(controller: phoneCtrl, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'মোবাইল নম্বর')),
            TextField(controller: rateCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'মাসিক চাঁদা (টাকা)')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
          ElevatedButton(
            onPressed: () async {
              if (nameCtrl.text.trim().isEmpty) return;
              final rate = (int.tryParse(rateCtrl.text) ?? 200) * 100;
              await _db!.insert('members', {
                'name': nameCtrl.text.trim(),
                'phone': phoneCtrl.text.trim(),
                'monthly_rate': rate,
              });
              Navigator.pop(ctx);
              _loadData();
            },
            child: const Text('সংরক্ষণ'),
          ),
        ],
      ),
    );
  }

  void _collectFee(Map<String, dynamic> item) {
    final due = item['due'] as int;
    final rate = item['rate'] as int;
    final defaultAmount = due > 0 ? (due ~/ 100) : (rate ~/ 100);
    final amountCtrl = TextEditingController(text: defaultAmount.toString());

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${item['name']} — চাঁদা আদায়'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('ধার্য: ${BanglaHelper.formatTaka(rate)} | বকেয়া: ${BanglaHelper.formatTaka(due)}'),
            const SizedBox(height: 10),
            TextField(controller: amountCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'আদায়ের পরিমাণ (টাকা)', border: OutlineInputBorder())),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
          ElevatedButton(
            onPressed: () async {
              final val = int.tryParse(amountCtrl.text) ?? 0;
              if (val <= 0) return;
              await _db!.insert('collections', {
                'member_id': item['id'],
                'year': _curYear,
                'month': _curMonth,
                'amount': val * 100,
                'date': DateTime.now().toIso8601String(),
              });
              Navigator.pop(ctx);
              _loadData();
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('চাঁদা সফলভাবে জমা হয়েছে!')));
            },
            child: const Text('জমা করুন'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    int totalRate = _memberList.fold(0, (s, i) => s + (i['rate'] as int));
    int totalPaid = _memberList.fold(0, (s, i) => s + (i['paid'] as int));
    int totalDue = _memberList.fold(0, (s, i) => s + (i['due'] as int));

    return Scaffold(
      appBar: AppBar(
        title: const Text('মিয়াপাড়া কেন্দ্রীয় জামে মসজিদ', style: TextStyle(fontSize: 18, color: Colors.white)),
        backgroundColor: Colors.teal[800],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addMember,
        backgroundColor: Colors.teal[800],
        icon: const Icon(Icons.person_add, color: Colors.white),
        label: const Text('নতুন সদস্য', style: TextStyle(color: Colors.white)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  color: Colors.teal.shade50,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${BanglaHelper.months[_curMonth]} ${BanglaHelper.toBn(_curYear)}',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back),
                            onPressed: () {
                              setState(() {
                                if (_curMonth == 1) { _curMonth = 12; _curYear--; }
                                else { _curMonth--; }
                              });
                              _loadData();
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.arrow_forward),
                            onPressed: () {
                              setState(() {
                                if (_curMonth == 12) { _curMonth = 1; _curYear++; }
                                else { _curMonth++; }
                              });
                              _loadData();
                            },
                          ),
                        ],
                      )
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    children: [
                      _card('ধার্য', BanglaHelper.formatTaka(totalRate), Colors.blueGrey),
                      const SizedBox(width: 6),
                      _card('আদায়', BanglaHelper.formatTaka(totalPaid), Colors.teal),
                      const SizedBox(width: 6),
                      _card('বকেয়া', BanglaHelper.formatTaka(totalDue), Colors.redAccent),
                    ],
                  ),
                ),
                Expanded(
                  child: _memberList.isEmpty
                      ? const Center(child: Text('কোন সদস্য নেই। নিচে থেকে সদস্য যোগ করুন।'))
                      : ListView.separated(
                          itemCount: _memberList.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (ctx, idx) {
                            final m = _memberList[idx];
                            final isPaid = m['due'] == 0 && m['rate'] > 0;
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: isPaid ? Colors.teal.shade100 : Colors.red.shade100,
                                child: Icon(isPaid ? Icons.check : Icons.person, color: isPaid ? Colors.teal : Colors.red),
                              ),
                              title: Text(m['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: Text('ধার্য: ${BanglaHelper.formatTaka(m['rate'])} | আদায়: ${BanglaHelper.formatTaka(m['paid'])}' + (m['due'] > 0 ? ' | বকেয়া: ${BanglaHelper.formatTaka(m['due'])}' : '')),
                              trailing: ElevatedButton(
                                style: ElevatedButton.styleFrom(backgroundColor: isPaid ? Colors.grey.shade300 : Colors.teal),
                                onPressed: () => _collectFee(m),
                                child: Text(isPaid ? 'পুনরায়' : 'আদায়', style: TextStyle(color: isPaid ? Colors.black : Colors.white)),
                              ),
                            );
                          },
                        ),
                )
              ],
            ),
    );
  }

  Widget _card(String t, String v, Color c) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
        child: Column(
          children: [
            Text(t, style: TextStyle(fontSize: 12, color: c)),
            Text(v, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: c)),
          ],
        ),
      ),
    );
  }
}
