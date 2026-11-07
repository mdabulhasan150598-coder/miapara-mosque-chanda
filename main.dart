import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MiaparaChandaApp());
}

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
    final path = p.join(dbPath, 'miapara_chanda_v2.db');

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
            receipt_no TEXT,
            date TEXT,
            note TEXT
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

  // স্বয়ংক্রিয় বহু-মাস চাঁদা বণ্টন (Auto-allocation)
  Future<void> _processPayment(Map<String, dynamic> item, int totalTaka, String note) async {
    int remainingPaisa = totalTaka * 100;
    int mId = item['id'] as int;
    int rate = item['rate'] as int;
    int y = _curYear;
    int m = _curMonth;

    final receiptNo = 'RCP-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';
    final nowStr = DateTime.now().toIso8601String();

    while (remainingPaisa > 0) {
      final res = await _db!.rawQuery('''
        SELECT COALESCE(SUM(amount), 0) as paid 
        FROM collections 
        WHERE member_id = ? AND year = ? AND month = ?
      ''', [mId, y, m]);

      int alreadyPaid = res.first['paid'] as int;
      int need = (rate > alreadyPaid) ? (rate - alreadyPaid) : rate;

      int alloc = (remainingPaisa >= need) ? need : remainingPaisa;

      await _db!.insert('collections', {
        'member_id': mId,
        'year': y,
        'month': m,
        'amount': alloc,
        'receipt_no': receiptNo,
        'date': nowStr,
        'note': note,
      });

      remainingPaisa -= alloc;
      m++;
      if (m > 12) {
        m = 1;
        y++;
      }
    }

    _loadData();

    // পেমেন্ট শেষে স্বয়ংক্রিয় রসিদ প্রিন্ট করার ডায়ালগ
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('চাঁদা সফলভাবে জমা হয়েছে!'),
          backgroundColor: Colors.teal[800],
          action: SnackBarAction(
            label: 'রসিদ প্রিন্ট',
            textColor: Colors.amber,
            onPressed: () => _printSingleReceipt(item['name'], item['phone'], totalTaka * 100, receiptNo, _curYear, _curMonth),
          ),
        ),
      );
    }
  }

  // ১. ডিজিটাল বাংলা রসিদ PDF জেনারেটর
  Future<void> _printSingleReceipt(String name, dynamic phone, int amountPaisa, String receiptNo, int year, int month) async {
    final doc = pw.Document();
    pw.Font? ttf;
    try {
      ttf = await PdfGoogleFonts.notoSansBengaliRegular();
    } catch (_) {
      ttf = pw.Font.helvetica();
    }

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a6,
        build: (pw.Context ctx) {
          return pw.Container(
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.teal, width: 1.5),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Text('মিয়াপাড়া কেন্দ্রীয় জামে মসজিদ', style: pw.TextStyle(font: ttf, fontSize: 13, fontWeight: pw.FontWeight.bold, color: PdfColors.teal800)),
                pw.Text('মাসিক চাঁদা আদায় রসিদ', style: pw.TextStyle(font: ttf, fontSize: 9, color: PdfColors.grey700)),
                pw.Divider(thickness: 0.8),
                pw.SizedBox(height: 4),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('রসিদ নং: $receiptNo', style: pw.TextStyle(font: ttf, fontSize: 8)),
                    pw.Text('তারিখ: ${BanglaHelper.toBn(DateTime.now().day)}/${BanglaHelper.toBn(DateTime.now().month)}/${BanglaHelper.toBn(DateTime.now().year)}', style: pw.TextStyle(font: ttf, fontSize: 8)),
                  ],
                ),
                pw.SizedBox(height: 8),
                pw.Align(
                  alignment: pw.Alignment.centerLeft,
                  child: pw.Text('চাঁদাদাতা: $name', style: pw.TextStyle(font: ttf, fontSize: 10, fontWeight: pw.FontWeight.bold)),
                ),
                if (phone != null && phone.toString().isNotEmpty)
                  pw.Align(
                    alignment: pw.Alignment.centerLeft,
                    child: pw.Text('মোবাইল: ${BanglaHelper.toBn(phone)}', style: pw.TextStyle(font: ttf, fontSize: 8)),
                  ),
                pw.SizedBox(height: 8),
                pw.Container(
                  padding: const pw.EdgeInsets.all(6),
                  color: PdfColors.grey200,
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text('বিবরণ: ${BanglaHelper.months[month]} ${BanglaHelper.toBn(year)}', style: pw.TextStyle(font: ttf, fontSize: 9)),
                      pw.Text(BanglaHelper.formatTaka(amountPaisa), style: pw.TextStyle(font: ttf, fontSize: 10, fontWeight: pw.FontWeight.bold)),
                    ],
                  ),
                ),
                pw.Spacer(),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      children: [
                        pw.Container(width: 50, height: 0.5, color: PdfColors.black),
                        pw.SizedBox(height: 2),
                        pw.Text('আদায়কারী', style: pw.TextStyle(font: ttf, fontSize: 7)),
                      ],
                    ),
                    pw.Column(
                      children: [
                        pw.Container(width: 50, height: 0.5, color: PdfColors.black),
                        pw.SizedBox(height: 2),
                        pw.Text('সভাপতি / মুহতামিম', style: pw.TextStyle(font: ttf, fontSize: 7)),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );

    await Printing.layoutPdf(onLayout: (format) async => doc.save(), name: 'Receipt_$receiptNo.pdf');
  }

  // ২. পুরো মাসের পূর্ণাঙ্গ খাতা / রিপোর্ট PDF প্রিন্ট
  Future<void> _printMonthlyReport() async {
    final doc = pw.Document();
    pw.Font? ttf;
    try {
      ttf = await PdfGoogleFonts.notoSansBengaliRegular();
    } catch (_) {
      ttf = pw.Font.helvetica();
    }

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context ctx) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Center(
                child: pw.Text('মিয়াপাড়া কেন্দ্রীয় জামে মসজিদ', style: pw.TextStyle(font: ttf, fontSize: 16, fontWeight: pw.FontWeight.bold)),
              ),
              pw.Center(
                child: pw.Text('মাসিক চাঁদা রেজিস্টার — ${BanglaHelper.months[_curMonth]} ${BanglaHelper.toBn(_curYear)}', style: pw.TextStyle(font: ttf, fontSize: 11)),
              ),
              pw.SizedBox(height: 12),
              pw.TableHelper.fromTextArray(
                headers: ['ক্রমিক', 'নাম', 'মোবাইল', 'ধার্য চাঁদা', 'আদায়', 'বকেয়া', 'স্ট্যাটাস'],
                data: _memberList.asMap().entries.map((e) {
                  final m = e.value;
                  return [
                    BanglaHelper.toBn(e.key + 1),
                    m['name'],
                    BanglaHelper.toBn(m['phone'] ?? '-'),
                    BanglaHelper.formatTaka(m['rate']),
                    BanglaHelper.formatTaka(m['paid']),
                    BanglaHelper.formatTaka(m['due']),
                    (m['due'] == 0 && m['rate'] > 0) ? 'পরিশোধিত' : 'বকেয়া',
                  ];
                }).toList(),
                headerStyle: pw.TextStyle(font: ttf, fontWeight: pw.FontWeight.bold, fontSize: 9),
                cellStyle: pw.TextStyle(font: ttf, fontSize: 8),
              ),
            ],
          );
        },
      ),
    );

    await Printing.layoutPdf(onLayout: (format) async => doc.save(), name: 'Monthly_Report_${_curMonth}_$_curYear.pdf');
  }

  // চাঁদা আদায়ের পপ-আপ
  void _collectFee(Map<String, dynamic> item) {
    final due = item['due'] as int;
    final rate = item['rate'] as int;
    final defaultAmount = due > 0 ? (due ~/ 100) : (rate ~/ 100);
    final amountCtrl = TextEditingController(text: defaultAmount.toString());
    final noteCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${item['name']} — চাঁদা আদায়'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('ধার্য: ${BanglaHelper.formatTaka(rate)} | বকেয়া: ${BanglaHelper.formatTaka(due)}'),
              const SizedBox(height: 8),
              const Text('একাধিক মাসের টাকা একসাথে দিলে স্বয়ংক্রিয়ভাবে পরবর্তী মাসগুলোতে হিসাব ভাগ হয়ে যাবে।', style: TextStyle(fontSize: 11, color: Colors.blueGrey)),
              const SizedBox(height: 10),
              TextField(
                controller: amountCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'জমার পরিমাণ (টাকা)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: noteCtrl,
                decoration: const InputDecoration(labelText: 'মন্তব্য (ঐচ্ছিক)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('বাতিল')),
          ElevatedButton(
            onPressed: () {
              final val = int.tryParse(amountCtrl.text) ?? 0;
              if (val <= 0) return;
              Navigator.pop(ctx);
              _processPayment(item, val, noteCtrl.text.trim());
            },
            child: const Text('জমা ও রসিদ'),
          ),
        ],
      ),
    );
  }

  void _addMember() {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final rateCtrl = TextEditingController(text: '200');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('নতুন চাঁদাদাতা যোগ'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'নাম (বাধ্যতামূলক)')),
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

  @override
  Widget build(BuildContext context) {
    int totalRate = _memberList.fold(0, (s, i) => s + (i['rate'] as int));
    int totalPaid = _memberList.fold(0, (s, i) => s + (i['paid'] as int));
    int totalDue = _memberList.fold(0, (s, i) => s + (i['due'] as int));

    return Scaffold(
      appBar: AppBar(
        title: const Text('মিয়াপাড়া কেন্দ্রীয় জামে মসজিদ', style: TextStyle(fontSize: 17, color: Colors.white)),
        backgroundColor: Colors.teal[800],
        actions: [
          IconButton(
            icon: const Icon(Icons.print, color: Colors.white),
            tooltip: 'পুরো মাসের খাতা প্রিন্ট',
            onPressed: _printMonthlyReport,
          ),
        ],
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
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                      _card('মোট আদায়', BanglaHelper.formatTaka(totalPaid), Colors.teal),
                      const SizedBox(width: 6),
                      _card('মোট বকেয়া', BanglaHelper.formatTaka(totalDue), Colors.redAccent),
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
