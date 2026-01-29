#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Encode qw(encode_utf8);
use IO::Socket::INET;
use IO::Select;
use POSIX qw(:sys_wait_h);
use Errno qw(EAGAIN EWOULDBLOCK);
use Time::HiRes;

# Mock VM for testing serencp.pl
# Listens on TCP 127.0.0.1:4555 and simulates VM serial console output

binmode(STDOUT, ':encoding(UTF-8)');

our $PORT = 4555;
our $LISTEN_ADDR = '127.0.0.1';

# Unicode text in various languages for testing
our %KERNEL_MESSAGES = (
    english => [
        "Booting kernel...",
        "Loading initial ramdisk...",
        "Mounting root filesystem...",
        "Starting system services...",
        "Network interface eth0 initialized",
        "System ready.",
    ],
    french => [
        "Démarrage du noyau...",
        "Chargement du ramdisk initial...",
        "Montage du système de fichiers racine...",
        "Démarrage des services système...",
        "Interface réseau eth0 initialisée",
        "Système prêt.",
    ],
    korean => [
        "커널 부팅 중...",
        "초기 램디스크 로딩 중...",
        "루트 파일 시스템 마운트 중...",
        "시스템 서비스 시작 중...",
        "네트워크 인터페이스 eth0 초기화됨",
        "시스템 준비 완료.",
    ],
    japanese => [
        "カーネルを起動中...",
        "初期RAMディスクを読み込み中...",
        "ルートファイルシステムをマウント中...",
        "システムサービスを開始中...",
        "ネットワークインターフェースeth0を初期化しました",
        "システム準備完了。",
    ],
    arabic => [
        "جاري تشغيل النواة...",
        "جاري تحميل ذاكرة الوصول العشوائي الأولية...",
        "جاري تركيب نظام الملفات الجذر...",
        "جاري بدء خدمات النظام...",
        "تم تهيئة واجهة الشبكة eth0",
        "النظام جاهز.",
    ],
    hindi => [
        "कर्नेल बूट हो रहा है...",
        "प्रारंभिक रैमडिस्क लोड हो रहा है...",
        "रूट फाइल सिस्टम माउंट हो रहा है...",
        "सिस्टम सेवाएं शुरू हो रही हैं...",
        "नेटवर्क इंटरफेस eth0 प्रारंभित",
        "सिस्टम तैयार है।",
    ],
    chinese => [
        "正在启动内核...",
        "正在加载初始内存盘...",
        "正在挂载根文件系统...",
        "正在启动系统服务...",
        "网络接口 eth0 已初始化",
        "系统就绪。",
    ],
    russian => [
        "Загрузка ядра...",
        "Загрузка начального ramdisk...",
        "Монтирование корневой файловой системы...",
        "Запуск системных служб...",
        "Сетевой интерфейс eth0 инициализирован",
        "Система готова.",
    ],
    greek => [
        "Εκκίνηση πυρήνα...",
        "Φόρτωση αρχικού ramdisk...",
        "Προσάρτηση ριζικού συστήματος αρχείων...",
        "Εκκίνηση υπηρεσιών συστήματος...",
        "Διεπαφή δικτύου eth0 αρχικοποιήθηκε",
        "Το σύστημα είναι έτοιμο.",
    ],
    hebrew => [
        "מפעיל את הקרנל...",
        "טוען את דיסק ה-RAM הראשוני...",
        "מעמיד את מערכת הקבצים הראשית...",
        "מפעיל שירותי מערכת...",
        "ממשק הרשת eth0 אותחל",
        "המערכת מוכנה.",
    ],
    thai => [
        "กำลังบูตเคอร์เนล...",
        "กำลังโหลดแรมดิสก์เริ่มต้น...",
        "กำลังเมานต์ระบบไฟล์รูท...",
        "กำลังเริ่มบริการระบบ...",
        "อินเทอร์เฟซเครือข่าย eth0 เริ่มต้นแล้ว",
        "ระบบพร้อมใช้งาน",
    ],
    vietnamese => [
        "Đang khởi động kernel...",
        "Đang tải ramdisk ban đầu...",
        "Đang gắn hệ thống tệp gốc...",
        "Đang khởi động dịch vụ hệ thống...",
        "Giao diện mạng eth0 đã được khởi tạo",
        "Hệ thống sẵn sàng.",
    ],
);

our @HELLO_WORLD = (
    "Hello World! (English)",
    "Bonjour le monde! (French)",
    "안녕하세요 세계! (Korean)",
    "こんにちは世界! (Japanese)",
    "مرحبا بالعالم! (Arabic)",
    "नमस्ते दुनिया! (Hindi)",
);

# Create listening socket
my $server = IO::Socket::INET->new(
    LocalAddr => $LISTEN_ADDR,
    LocalPort => $PORT,
    Proto     => 'tcp',
    Listen    => 5,
    ReuseAddr => 1,
) or die "Cannot create server socket: $!\n";

print "Mock VM listening on $LISTEN_ADDR:$PORT\n";
print "Waiting for connections...\n";

my $select = IO::Select->new($server);

while (1) {
    my @ready = $select->can_read();
    
    for my $fh (@ready) {
        if ($fh == $server) {
            # New connection
    my $client = $server->accept();
    next unless $client;
    
    print "Client connected from " . $client->peerhost() . "\n";
            
            # Fork to handle client
            my $pid = fork();
            if (!defined $pid) {
                print "Fork failed: $!\n";
                close($client);
                next;
            }
            
            if ($pid == 0) {
                # Child process
                close($server);
                $select->remove($server);
                handle_client($client);
                exit(0);
            } else {
                # Parent process
                close($client);
            }
        }
    }
    
    # Reap zombie processes
    while (waitpid(-1, WNOHANG) > 0) { }
}

sub handle_client {
    my ($client) = @_;
    
    $client->autoflush(1);
    
    # Send GRUB menu
    my $grub_menu = <<'MENU';

GNU GRUB  version 2.06

┌────────────────────────────────────────────────────────────┐
│*Ubuntu                                                     │
│ Advanced options for Ubuntu                                │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
└────────────────────────────────────────────────────────────┘

Use the ↑ and ↓ keys to select which entry is highlighted.
Press enter to boot the selected OS, `e' to edit the commands
before booting or `c' for a command-line.

MENU
    
    print $client encode_utf8($grub_menu);
    
    # Auto-select option 1 after sending GRUB menu
    # (simplified for testing - real VM would wait for input)
    my $selection = 0;  # Always select Ubuntu
    sleep(1);  # Brief pause to simulate GRUB timeout
    
    # Clear screen and show selection
    print $client "\n\nBooting selection " . ($selection + 1) . "...\n\n";
    
    if ($selection == 0) {
        # Option 1: Load Linux with kernel messages in various languages
        boot_linux($client);
    } else {
        # Option 2: Hello World in multiple languages
        hello_world_mode($client);
    }
    
    close($client);
    print "Client session ended\n";
}

sub boot_linux {
    my ($client) = @_;
    
    $client->autoflush(1);
    
    print $client "Loading Linux 5.15.0-generic ...\n";
    Time::HiRes::sleep(0.005);
    
    # Get all messages from all languages
    my @all_messages;
    for my $lang (keys %KERNEL_MESSAGES) {
        push @all_messages, @{$KERNEL_MESSAGES{$lang}};
    }
    
    # Shuffle messages for variety
    for (my $i = @all_messages - 1; $i > 0; $i--) {
        my $j = int(rand($i + 1));
        @all_messages[$i, $j] = @all_messages[$j, $i];
    }
    
    # Print kernel messages with delay
    my $counter = 0;
    for my $msg (@all_messages) {
        my $timestamp = sprintf("[%8.6f]", $counter * 0.005);
        print $client $timestamp . " " . encode_utf8($msg) . "\n";
        Time::HiRes::sleep(0.005);
        $counter++;
    }
    
    # Continue with more messages indefinitely
    print $client "\n";
    print $client encode_utf8("╔════════════════════════════════════════════════════════════╗\n");
    print $client encode_utf8("║           Linux Boot Complete - Login Prompt               ║\n");
    print $client encode_utf8("╚════════════════════════════════════════════════════════════╝\n");
    print $client "\n";
    print $client "mockvm login: _\n";
    
    # Keep connection alive indefinitely - only close on signal or explicit exit
    # Use a loop that just sleeps and doesn't try to read
    while (1) {
        Time::HiRes::sleep(1);
    }
}
    
sub hello_world_mode {
    my ($client) = @_;
    
    print $client encode_utf8("╔════════════════════════════════════════════════════════════╗\n");
    print $client encode_utf8("║           Hello World Mode - Random Output                 ║\n");
    print $client encode_utf8("╚════════════════════════════════════════════════════════════╝\n");
    print $client "\n";
    print $client encode_utf8("Press Ctrl+C or disconnect to exit\n");
    print $client "\n";
    
    my $counter = 0;
    while (1) {
        # Pick random hello world message
        my $msg = $HELLO_WORLD[int(rand(@HELLO_WORLD))];
        my $timestamp = sprintf("[%06d]", $counter);
        print $client $timestamp . " " . encode_utf8($msg) . "\n";
        
        Time::HiRes::sleep(0.005);
        $counter++;
        
        # Limit counter display
        $counter = 0 if $counter > 999999;
    }
}

# Cleanup on signal
local $SIG{INT} = local $SIG{TERM} = sub {
    print "\nShutting down mock VM...\n";
    close($server);
    exit(0);
};
