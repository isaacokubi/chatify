import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

class Api {
  String get base => const String.fromEnvironment('CHATIFY_API', defaultValue: 'http://10.0.2.2:5000');
  String? token;
  Future<void> restore() async { token = (await SharedPreferences.getInstance()).getString('token'); }
  Future<Map<String,dynamic>> call(String method,String path,[Map<String,dynamic>? body]) async {
    final h={'Content-Type':'application/json',if(token!=null)'Authorization':'Bearer $token'};
    final u=Uri.parse('$base$path'); late http.Response r;
    if (method == 'POST') { r = await http.post(u, headers: h, body: jsonEncode(body ?? {})); }
    else if (method == 'PATCH') { r = await http.patch(u, headers: h, body: jsonEncode(body ?? {})); }
    else if (method == 'DELETE') { r = await http.delete(u, headers: h); }
    else { r = await http.get(u, headers: h); }
    final d=r.body.isEmpty?<String,dynamic>{}:jsonDecode(r.body);
    if(r.statusCode>=400) throw Exception(d is Map&&d['error']!=null?d['error']:'Request failed');
    return d is Map?Map<String,dynamic>.from(d):{'data':d};
  }
}
class AppState extends ChangeNotifier {
  final api=Api(); bool ready=false; Map<String,dynamic>? user;
  AppState(){init();}
  Future<void> init() async { await api.restore(); if(api.token!=null){try{user=Map<String,dynamic>.from((await api.call('GET','/api/auth/me'))['user']);}catch(_){await logout();}} ready=true; notifyListeners(); }
  Future<String?> auth(bool reg,String name,String email,String pass) async {try{final d=await api.call('POST',reg?'/api/auth/register':'/api/auth/login',reg?{'name':name,'email':email,'password':pass}:{'email':email,'password':pass});api.token=d['token'];user=Map<String,dynamic>.from(d['user']);await (await SharedPreferences.getInstance()).setString('token',api.token!);notifyListeners();return null;}catch(e){return e.toString().replaceFirst('Exception: ','');}}
  Future<void> logout() async {api.token=null;user=null;await (await SharedPreferences.getInstance()).remove('token');notifyListeners();}
}
void main()=>runApp(ChangeNotifierProvider(create:(_)=>AppState(),child:const ChatifyApp()));
class ChatifyApp extends StatelessWidget{
 const ChatifyApp({super.key});
 @override Widget build(BuildContext context)=>MaterialApp(debugShowCheckedModeBanner:false,title:'Chatify',theme:ThemeData(useMaterial3:true,colorSchemeSeed:const Color(0xFF6558D3)),home:Consumer<AppState>(builder:(_,a,__)=>(a.ready&&a.user!=null)?const Home():a.ready?const Auth():const Scaffold(body:Center(child:CircularProgressIndicator()))));
}
class Auth extends StatefulWidget{const Auth({super.key});@override State<Auth> createState()=>_AuthState();}
class _AuthState extends State<Auth>{
 bool reg=false,busy=false,hide=true;final n=TextEditingController(),e=TextEditingController(),p=TextEditingController();
 @override void dispose(){n.dispose();e.dispose();p.dispose();super.dispose();}
 Future<void> submit()async{if(e.text.trim().isEmpty||p.text.length<8||(reg&&n.text.trim().isEmpty)){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Complete all fields. Password must be 8+ characters.')));return;}setState(()=>busy=true);final err=await context.read<AppState>().auth(reg,n.text.trim(),e.text.trim(),p.text);if(mounted){setState(()=>busy=false);if(err!=null)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(err)));}}
 @override Widget build(BuildContext context)=>Scaffold(body:SafeArea(child:Center(child:SingleChildScrollView(padding:const EdgeInsets.all(28),child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:430),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[const Icon(Icons.forum_rounded,size:70),const SizedBox(height:10),const Text('Chatify',textAlign:TextAlign.center,style:TextStyle(fontSize:40,fontWeight:FontWeight.w800)),const Text('Chat. Remember. Let Go.',textAlign:TextAlign.center),const SizedBox(height:30),if(reg)TextField(controller:n,decoration:const InputDecoration(labelText:'Full name',border:OutlineInputBorder())),if(reg)const SizedBox(height:12),TextField(controller:e,keyboardType:TextInputType.emailAddress,decoration:const InputDecoration(labelText:'Email address',border:OutlineInputBorder())),const SizedBox(height:12),TextField(controller:p,obscureText:hide,onSubmitted:(_)=>submit(),decoration:InputDecoration(labelText:'Password',border:const OutlineInputBorder(),suffixIcon:IconButton(onPressed:()=>setState(()=>hide=!hide),icon:Icon(hide?Icons.visibility:Icons.visibility_off)))),const SizedBox(height:18),FilledButton(onPressed:busy?null:submit,child:Text(reg?'Create account':'Sign in')),TextButton(onPressed:()=>setState(()=>reg=!reg),child:Text(reg?'Already have an account? Sign in':'Create a new account'))]))))));
}
class Home extends StatefulWidget{const Home({super.key});@override State<Home> createState()=>_HomeState();}
class _HomeState extends State<Home>{
 int tab=0;List<dynamic> chats=[],users=[],memories=[];bool loading=false;AppState get app=>context.read<AppState>();
 @override void initState(){super.initState();loadChats();}
 Future<void> loadChats()async{setState(()=>loading=true);try{chats=List<dynamic>.from((await app.api.call('GET','/api/conversations'))['conversations']??[]);}catch(_){}if(mounted)setState(()=>loading=false);}
 Future<void> search(String q)async{if(q.trim().length<2){setState(()=>users=[]);return;}try{users=List<dynamic>.from((await app.api.call('GET','/api/users/search?q=${Uri.encodeQueryComponent(q.trim())}'))['users']??[]);if(mounted)setState((){});}catch(_){}}
 Future<void> loadMemories()async{try{memories=List<dynamic>.from((await app.api.call('GET','/api/memories'))['memories']??[]);if(mounted)setState((){});}catch(_){}}
 @override
 Widget build(BuildContext context) {
   final titles = ['Chats', 'Memories', 'Contacts', 'Profile'];
   return Scaffold(
     appBar: AppBar(
       title: Text(titles[tab]),
       actions: [
         if (tab == 0) IconButton(onPressed: loadChats, icon: const Icon(Icons.refresh)),
         if (tab == 2) IconButton(onPressed: _newGroup, icon: const Icon(Icons.group_add)),
       ],
     ),
     body: IndexedStack(index: tab, children: [_chats(), _memories(), _contacts(), const Profile()]),
     bottomNavigationBar: NavigationBar(
       selectedIndex: tab,
       onDestinationSelected: (i) {
         setState(() => tab = i);
         if (i == 0) loadChats();
         if (i == 1) loadMemories();
       },
       destinations: const [
         NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Chats'),
         NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), label: 'Memories'),
         NavigationDestination(icon: Icon(Icons.people_outline), label: 'Contacts'),
         NavigationDestination(icon: Icon(Icons.person_outline), label: 'Profile'),
       ],
     ),
   );
 }
 Widget _chats() {
  if (loading) return const Center(child: CircularProgressIndicator());
  if (chats.isEmpty) return const Empty(icon: Icons.forum_outlined, title: 'No conversations', subtitle: 'Search Contacts to start a chat.');
  return RefreshIndicator(
    onRefresh: loadChats,
    child: ListView.builder(
      itemCount: chats.length,
      itemBuilder: (_, i) {
        final c = Map<String, dynamic>.from(chats[i]);
        final ps = List<dynamic>.from(c['participants'] ?? []);
        final me = app.user?['id']?.toString();
        Map<String, dynamic>? other;
        for (final raw in ps) {
          final person = Map<String, dynamic>.from(raw);
          if (person['_id']?.toString() != me) { other = person; break; }
        }
        final title = c['type'] == 'group' ? (c['title'] ?? 'Group').toString() : (other?['name'] ?? 'Chat').toString();
        final last = c['lastMessage'];
        final preview = last is Map ? (last['text'] ?? 'Start chatting').toString() : 'Start chatting';
        return ListTile(
          leading: CircleAvatar(child: Text(title.isEmpty ? '?' : title[0].toUpperCase())),
          title: Text(title),
          subtitle: Text(preview),
          onTap: () { Navigator.push(context, MaterialPageRoute(builder: (_) => Chat(conversation: c))).then((_) => loadChats()); },
        );
      },
    ),
  );
 }

 Widget _contacts() {
  return Column(children: [
    Padding(padding: const EdgeInsets.all(16), child: TextField(onChanged: search, decoration: const InputDecoration(labelText: 'Search people', prefixIcon: Icon(Icons.search), border: OutlineInputBorder()))),
    Expanded(child: users.isEmpty
      ? const Empty(icon: Icons.person_search, title: 'Find people', subtitle: 'Search by name or email.')
      : ListView.builder(itemCount: users.length, itemBuilder: (_, i) {
          final u = Map<String, dynamic>.from(users[i]);
          final displayName = u['name']?.toString() ?? 'User';
          return ListTile(
            leading: CircleAvatar(child: Text(displayName.isEmpty ? '?' : displayName[0].toUpperCase())),
            title: Text(displayName),
            subtitle: Text(u['email']?.toString() ?? ''),
            onTap: () async {
              try {
                final d = await app.api.call('POST', '/api/conversations/direct', {'userId': u['_id']});
                if (!mounted) return;
                Navigator.push(context, MaterialPageRoute(builder: (_) => Chat(conversation: Map<String, dynamic>.from(d['conversation']))));
              } catch (error) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
              }
            },
          );
        })),
  ]);
 }

 Widget _memories() {
  if (memories.isEmpty) return const Empty(icon: Icons.auto_awesome, title: 'No memories saved', subtitle: 'Save useful events, tasks, places and payments.');
  return ListView.builder(
    padding: const EdgeInsets.all(12),
    itemCount: memories.length,
    itemBuilder: (_, i) {
      final memory = Map<String, dynamic>.from(memories[i]);
      return Dismissible(
        key: ValueKey(memory['_id']),
        direction: DismissDirection.endToStart,
        background: Container(alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete_outline)),
        onDismissed: (_) async { try { await app.api.call('DELETE', '/api/memories/${memory['_id']}'); } catch (_) {} },
        child: Card(child: ListTile(title: Text(memory['title']?.toString() ?? 'Memory'), subtitle: Text(memory['description']?.toString() ?? ''))),
      );
    },
  );
 }

 Future<void> _newGroup() async {
  final title = TextEditingController();
  final email = TextEditingController();
  await showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Create group'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: title, decoration: const InputDecoration(labelText: 'Group name')),
          TextField(controller: email, decoration: const InputDecoration(labelText: 'Member email')),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            try {
              final result = await app.api.call('GET', '/api/users/search?q=${Uri.encodeQueryComponent(email.text.trim())}');
              final found = List<dynamic>.from(result['users'] ?? []);
              if (found.isEmpty) throw Exception('Member not found');
              final created = await app.api.call('POST', '/api/conversations/group', {
                'title': title.text.trim(),
                'memberIds': [found.first['_id']],
              });
              if (dialog.mounted) Navigator.pop(dialog);
              if (!mounted) return;
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => Chat(conversation: Map<String, dynamic>.from(created['conversation'])),
              ));
            } catch (error) {
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
            }
          },
          child: const Text('Create'),
        ),
      ],
    ),
  );
  title.dispose();
  email.dispose();
}
}
class Empty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const Empty({super.key, required this.icon, required this.title, required this.subtitle});
  @override
  Widget build(BuildContext context) {
    return Center(child: Padding(
      padding: const EdgeInsets.all(30),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 60),
        const SizedBox(height: 12),
        Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text(subtitle, textAlign: TextAlign.center),
      ]),
    ));
  }
}

class Chat extends StatefulWidget {
  final Map<String, dynamic> conversation;
  const Chat({super.key, required this.conversation});
  @override
  State<Chat> createState() => _ChatState();
}

class _ChatState extends State<Chat> {
  final input = TextEditingController();
  List<dynamic> messages = [];
  String expiry = 'NONE';
  String? reply;
  io.Socket? socket;
  bool loading = true;
  AppState get app => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    load();
    connect();
  }

  Future<void> load() async {
    try {
      final result = await app.api.call('GET', '/api/conversations/${widget.conversation['_id']}/messages');
      messages = List<dynamic>.from(result['messages'] ?? []);
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  void connect() {
    socket = io.io(
      app.api.base,
      io.OptionBuilder().setTransports(['websocket']).setAuth({'token': app.api.token}).disableAutoConnect().build(),
    );
    socket!.connect();
    socket!.onConnect((_) => socket!.emit('conversation:join', widget.conversation['_id']));
    socket!.on('message:new', (data) {
      if (!mounted || data is! Map) return;
      if (data['conversationId']?.toString() == widget.conversation['_id']?.toString()) {
        final incoming = Map<String, dynamic>.from(data);
        final id = incoming['_id']?.toString();
        if (id == null || !messages.any((item) => item is Map && item['_id']?.toString() == id)) {
          setState(() => messages.add(incoming));
        }
      }
    });
  }

  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty) return;
    try {
      final result = await app.api.call('POST', '/api/conversations/${widget.conversation['_id']}/messages', {
        'text': text,
        'expiryType': expiry,
        'expiresInSeconds': expiry == 'AFTER_TIME' ? 3600 : null,
        'replyTo': reply,
      });
      if (!mounted) return;
      setState(() {
        messages.add(Map<String, dynamic>.from(result['message']));
        reply = null;
      });
      input.clear();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  @override
  void dispose() {
    socket?.dispose();
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.conversation['type'] == 'group'
        ? (widget.conversation['title'] ?? 'Group').toString()
        : 'Chat';
    Future<void> extractMemory() async {
    try {
      final result = await app.api.call('POST', '/api/memories/extract', {'text': input.text.trim()});
      final candidates = List<dynamic>.from(result['candidates'] ?? []);
      if (!mounted) return;
      if (candidates.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No memory candidate found.')));
        return;
      }
      final selected = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Save a memory'),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: candidates.map((raw) {
                final item = Map<String, dynamic>.from(raw);
                return ListTile(
                  leading: const Icon(Icons.auto_awesome),
                  title: Text(item['title']?.toString() ?? 'Memory'),
                  subtitle: Text(item['description']?.toString() ?? ''),
                  onTap: () => Navigator.pop(dialog, item),
                );
              }).toList(),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel'))],
        ),
      );
      if (selected == null) return;
      await app.api.call('POST', '/api/memories', {
        ...selected,
        'conversationId': widget.conversation['_id'],
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Memory saved')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> reactTo(String messageId, String emoji) async {
    try {
      final result = await app.api.call('POST', '/api/messages/$messageId/reactions', {'emoji': emoji});
      final updated = Map<String, dynamic>.from(result['message']);
      final index = messages.indexWhere((item) => item is Map && item['_id']?.toString() == messageId);
      if (index >= 0 && mounted) setState(() => messages[index] = updated);
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> showMessageActions(Map<String, dynamic> message) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Wrap(
          children: [
            ListTile(leading: const Icon(Icons.reply), title: const Text('Reply'), onTap: () => Navigator.pop(sheet, 'reply')),
            ListTile(leading: const Text('❤️', style: TextStyle(fontSize: 22)), title: const Text('React with ❤️'), onTap: () => Navigator.pop(sheet, '❤️')),
            ListTile(leading: const Text('👍', style: TextStyle(fontSize: 22)), title: const Text('React with 👍'), onTap: () => Navigator.pop(sheet, '👍')),
            ListTile(leading: const Text('😂', style: TextStyle(fontSize: 22)), title: const Text('React with 😂'), onTap: () => Navigator.pop(sheet, '😂')),
          ],
        ),
      ),
    );
    if (action == null) return;
    if (action == 'reply') {
      setState(() => reply = message['_id']?.toString());
    } else if (message['_id'] != null) {
      await reactTo(message['_id'].toString(), action);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.conversation['type'] == 'group'
        ? (widget.conversation['title'] ?? 'Group').toString()
        : 'Chat';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(onPressed: extractMemory, tooltip: 'Save memory', icon: const Icon(Icons.auto_awesome)),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : messages.isEmpty
                  ? const Empty(icon: Icons.chat_bubble_outline, title: 'Start the conversation', subtitle: 'Send the first message.')
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: messages.length,
                      itemBuilder: (_, i) {
                        final message = Map<String, dynamic>.from(messages[i]);
                        final mine = message['senderId']?.toString() == app.user?['id']?.toString();
                        final text = message['expiredAt'] != null ? 'This message has expired.' : (message['text'] ?? '[media]').toString();
                        return GestureDetector(
                          onLongPress: () => showMessageActions(message),
                          child: Align(
                            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              constraints: const BoxConstraints(maxWidth: 330),
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: mine ? Theme.of(context).colorScheme.primaryContainer : Colors.white,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(text),
                            ),
                          ),
                        );
                      },
                    ),
        ),
        if (reply != null)
          const Padding(padding: EdgeInsets.all(6), child: Align(alignment: Alignment.centerLeft, child: Text('Replying to a message'))),
        SafeArea(child: Row(children: [
          PopupMenuButton<String>(
            onSelected: (value) => setState(() => expiry = value),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'NONE', child: Text('Permanent')),
              PopupMenuItem(value: 'AFTER_READ', child: Text('After read')),
              PopupMenuItem(value: 'AFTER_TIME', child: Text('After 1 hour')),
              PopupMenuItem(value: 'AFTER_REPLY', child: Text('After reply')),
            ],
          ),
          Expanded(child: TextField(controller: input, minLines: 1, maxLines: 5, decoration: const InputDecoration(hintText: 'Write a message…', border: InputBorder.none))),
          IconButton(onPressed: send, icon: const Icon(Icons.send)),
        ])),
      ]),
    );
  }
}

class Profile extends StatefulWidget{const Profile({super.key});@override State<Profile> createState()=>_ProfileState();}
class _ProfileState extends State<Profile>{late TextEditingController name,phone;bool lastSeen=true,receipts=true,messages=true,mentions=true,memories=true;
 @override void initState(){super.initState();final u=context.read<AppState>().user??{};name=TextEditingController(text:u['name']?.toString()??'');phone=TextEditingController(text:u['phone']?.toString()??'');final p=Map<String,dynamic>.from(u['privacy']??{}),n=Map<String,dynamic>.from(u['notificationPreferences']??{});lastSeen=p['lastSeen']??true;receipts=p['readReceipts']??true;messages=n['messages']??true;mentions=n['mentions']??true;memories=n['memories']??true;}
 @override void dispose(){name.dispose();phone.dispose();super.dispose();}
 Future<void> save() async {
  final api = context.read<AppState>().api;
  try {
    final d = await api.call('PATCH', '/api/users/me', {
      'name': name.text.trim(),
      'phone': phone.text.trim(),
      'privacy': {'lastSeen': lastSeen, 'readReceipts': receipts},
      'notificationPreferences': {'messages': messages, 'mentions': mentions, 'memories': memories},
    });
    if (!mounted) return;
    context.read<AppState>().user = Map<String, dynamic>.from(d['user']);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile saved')));
  } catch (e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
  }
}
 @override Widget build(BuildContext context)=>ListView(padding:const EdgeInsets.all(18),children:[TextField(controller:name,decoration:const InputDecoration(labelText:'Name',border:OutlineInputBorder())),const SizedBox(height:12),TextField(controller:phone,decoration:const InputDecoration(labelText:'Phone',border:OutlineInputBorder())),const SizedBox(height:18),const Text('Privacy',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),SwitchListTile(value:lastSeen,onChanged:(v)=>setState(()=>lastSeen=v),title:const Text('Show last seen')),SwitchListTile(value:receipts,onChanged:(v)=>setState(()=>receipts=v),title:const Text('Read receipts')),const Text('Notifications',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),SwitchListTile(value:messages,onChanged:(v)=>setState(()=>messages=v),title:const Text('New messages')),SwitchListTile(value:mentions,onChanged:(v)=>setState(()=>mentions=v),title:const Text('Mentions')),SwitchListTile(value:memories,onChanged:(v)=>setState(()=>memories=v),title:const Text('Memory suggestions')),FilledButton(onPressed:save,child:const Text('Save changes')),TextButton(onPressed:()=>context.read<AppState>().logout(),child:const Text('Sign out'))]);}
