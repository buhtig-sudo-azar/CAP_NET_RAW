/*
 * sniffer.c — программа для захвата сырых Ethernet-пакетов с ФИЛЬТРАЦИЕЙ
 * Поддерживает IPv4 и IPv6, показывает детали пакетов
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <net/ethernet.h>
#include <netinet/ip.h>
#include <netinet/ip6.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include <netinet/ip_icmp.h>
#include <netpacket/packet.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <signal.h>
#include <ctype.h>

// Флаг для обработки Ctrl+C
volatile sig_atomic_t running = 1;

void handle_signal(int sig)
{
    (void)sig;
    running = 0;
}

// Типы фильтра
enum filter_type
{
    FILTER_NONE,
    FILTER_IPV4,
    FILTER_IPV4_SUBNET,
    FILTER_IPV6
};

// Структура для хранения параметров фильтра
struct filter_config
{
    enum filter_type type;
    // для IPv4
    unsigned long addr_v4;
    unsigned long mask_v4;
    // для IPv6
    struct in6_addr addr_v6;
};

// Функция для парсинга IPv4 адреса или подсети
int parse_ipv4(const char *str, struct filter_config *fc)
{
    char *slash = strchr(str, '/');

    if (slash)
    {
        char ip_str[16];
        int prefix_len = slash - str;
        if (prefix_len >= 16)
            prefix_len = 15;
        strncpy(ip_str, str, prefix_len);
        ip_str[prefix_len] = '\0';

        struct in_addr addr;
        if (inet_pton(AF_INET, ip_str, &addr) != 1)
        {
            return 0;
        }

        int mask_bits = atoi(slash + 1);
        if (mask_bits < 0 || mask_bits > 32)
            mask_bits = 24;

        fc->type = FILTER_IPV4_SUBNET;
        fc->addr_v4 = addr.s_addr;

        if (mask_bits == 0)
        {
            fc->mask_v4 = 0;
        }
        else
        {
            fc->mask_v4 = htonl(~((1 << (32 - mask_bits)) - 1));
        }

        printf("[C] Фильтр IPv4 подсети: %s/%d\n", ip_str, mask_bits);
        return 1;
    }
    else
    {
        struct in_addr addr;
        if (inet_pton(AF_INET, str, &addr) != 1)
        {
            return 0;
        }

        fc->type = FILTER_IPV4;
        fc->addr_v4 = addr.s_addr;
        printf("[C] Фильтр IPv4: %s\n", str);
        return 1;
    }
}

// Функция для парсинга IPv6 адреса
int parse_ipv6(const char *str, struct filter_config *fc)
{
    struct in6_addr addr;
    if (inet_pton(AF_INET6, str, &addr) != 1)
    {
        return 0;
    }

    fc->type = FILTER_IPV6;
    fc->addr_v6 = addr;
    printf("[C] Фильтр IPv6: %s\n", str);
    return 1;
}

// Функция для парсинга фильтра
int parse_filter(const char *filter_str, struct filter_config *fc)
{
    if (!filter_str || strlen(filter_str) == 0 ||
        strcmp(filter_str, "any") == 0 ||
        strcmp(filter_str, "<нет>") == 0 ||
        strcmp(filter_str, "") == 0)
    {
        fc->type = FILTER_NONE;
        return 1;
    }

    if (parse_ipv4(filter_str, fc))
    {
        return 1;
    }

    if (parse_ipv6(filter_str, fc))
    {
        return 1;
    }

    fprintf(stderr, "[C] Неверный формат фильтра: %s\n", filter_str);
    fprintf(stderr, "    Поддерживаются: IPv4, IPv4/маска, IPv6\n");
    return 0;
}

// Функция проверки IPv4 пакета
int check_ipv4_packet(const struct ip *ip_hdr, struct filter_config *fc)
{
    unsigned long src_ip = ip_hdr->ip_src.s_addr;
    unsigned long dst_ip = ip_hdr->ip_dst.s_addr;

    if (fc->type == FILTER_IPV4)
    {
        return (src_ip == fc->addr_v4 || dst_ip == fc->addr_v4);
    }
    else if (fc->type == FILTER_IPV4_SUBNET)
    {
        return (((src_ip & fc->mask_v4) == (fc->addr_v4 & fc->mask_v4)) ||
                ((dst_ip & fc->mask_v4) == (fc->addr_v4 & fc->mask_v4)));
    }
    return 0;
}

// Функция проверки IPv6 пакета
int check_ipv6_packet(const struct ip6_hdr *ip6_hdr, struct filter_config *fc)
{
    if (fc->type != FILTER_IPV6)
        return 0;

    return (memcmp(&ip6_hdr->ip6_src, &fc->addr_v6, sizeof(struct in6_addr)) == 0 ||
            memcmp(&ip6_hdr->ip6_dst, &fc->addr_v6, sizeof(struct in6_addr)) == 0);
}

// Функция для определения протокола
const char *get_protocol_name(int proto)
{
    switch (proto)
    {
    case IPPROTO_TCP:
        return "TCP";
    case IPPROTO_UDP:
        return "UDP";
    case IPPROTO_ICMP:
        return "ICMP";
    case IPPROTO_ICMPV6:
        return "ICMPv6";
    default:
        return "OTHER";
    }
}

// Функция для безопасного вывода строк (без непечатных символов)
void safe_print(const char *str, int len)
{
    for (int i = 0; i < len && i < 50; i++)
    { // максимум 50 символов
        if (isprint(str[i]))
        {
            putchar(str[i]);
        }
        else
        {
            printf("\\x%02x", (unsigned char)str[i]);
        }
    }
}

// Функция для вывода деталей пакета
void print_packet_details(const unsigned char *buffer, int len, int packet_num)
{
    if (len < (int)sizeof(struct ether_header))
    {
        printf("[C] Пакет #%d: Слишком короткий (%d байт)\n", packet_num, len);
        return;
    }

    struct ether_header *eth = (struct ether_header *)buffer;
    unsigned short eth_type = ntohs(eth->ether_type);

    printf("[C] Пакет #%d | Размер: %d байт | ", packet_num, len);

    // Определяем тип пакета
    if (eth_type == ETHERTYPE_IP)
    {
        // IPv4
        if (len < (int)(sizeof(struct ether_header) + sizeof(struct ip)))
        {
            printf("IPv4 (неполный заголовок)");
        }
        else
        {
            struct ip *ip_hdr = (struct ip *)(buffer + sizeof(struct ether_header));
            char src_ip[INET_ADDRSTRLEN];
            char dst_ip[INET_ADDRSTRLEN];

            inet_ntop(AF_INET, &(ip_hdr->ip_src), src_ip, INET_ADDRSTRLEN);
            inet_ntop(AF_INET, &(ip_hdr->ip_dst), dst_ip, INET_ADDRSTRLEN);

            printf("IPv4 %s → %s [%s]",
                   src_ip, dst_ip,
                   get_protocol_name(ip_hdr->ip_p));
        }
    }
    else if (eth_type == ETHERTYPE_IPV6)
    {
        // IPv6
        if (len < (int)(sizeof(struct ether_header) + sizeof(struct ip6_hdr)))
        {
            printf("IPv6 (неполный заголовок)");
        }
        else
        {
            struct ip6_hdr *ip6_hdr = (struct ip6_hdr *)(buffer + sizeof(struct ether_header));
            char src_ip[INET6_ADDRSTRLEN];
            char dst_ip[INET6_ADDRSTRLEN];

            inet_ntop(AF_INET6, &(ip6_hdr->ip6_src), src_ip, INET6_ADDRSTRLEN);
            inet_ntop(AF_INET6, &(ip6_hdr->ip6_dst), dst_ip, INET6_ADDRSTRLEN);

            printf("IPv6 %s → %s", src_ip, dst_ip);
            // IPv6 протокол в следующем заголовке
        }
    }
    else if (eth_type == ETHERTYPE_ARP)
    {
        printf("ARP");
    }
    else
    {
        printf("Протокол: 0x%04x", eth_type);
    }

    // Если пакет маленький, покажем первые байты
    if (len < 100)
    {
        printf(" | Данные: ");
        safe_print((const char *)(buffer + sizeof(struct ether_header)),
                   len - sizeof(struct ether_header));
    }

    printf("\n");
}

// Функция проверки пакета на соответствие фильтру
int packet_matches_filter(const unsigned char *buffer, int len, struct filter_config *fc)
{
    if (fc->type == FILTER_NONE)
    {
        return 1;
    }

    if (len < (int)sizeof(struct ether_header))
    {
        return 0;
    }

    struct ether_header *eth = (struct ether_header *)buffer;
    unsigned short eth_type = ntohs(eth->ether_type);

    if (eth_type == ETHERTYPE_IP)
    {
        if (len < (int)(sizeof(struct ether_header) + sizeof(struct ip)))
        {
            return 0;
        }
        struct ip *ip_hdr = (struct ip *)(buffer + sizeof(struct ether_header));
        return check_ipv4_packet(ip_hdr, fc);
    }

    if (eth_type == ETHERTYPE_IPV6)
    {
        if (len < (int)(sizeof(struct ether_header) + sizeof(struct ip6_hdr)))
        {
            return 0;
        }
        struct ip6_hdr *ip6_hdr = (struct ip6_hdr *)(buffer + sizeof(struct ether_header));
        return check_ipv6_packet(ip6_hdr, fc);
    }

    return 0;
}

int main(int argc, char *argv[])
{
    signal(SIGINT, handle_signal);

    const char *output_file = "/tmp/dump.pcap";
    const char *interface = "eth0";
    const char *filter_str = "any";

    struct filter_config fc;
    fc.type = FILTER_NONE;

    if (argc > 1)
    {
        output_file = argv[1];
    }
    if (argc > 2)
    {
        interface = argv[2];
    }
    if (argc > 3)
    {
        filter_str = argv[3];
    }

    if (!parse_filter(filter_str, &fc))
    {
        fprintf(stderr, "[C] Ошибка парсинга фильтра. Использую 'any'.\n");
        fc.type = FILTER_NONE;
    }

    printf("[C] Сниффер запущен\n");
    printf("[C] Интерфейс: %s\n", interface);
    printf("[C] Дамп: %s\n", output_file);
    if (fc.type != FILTER_NONE)
    {
        printf("[C] Фильтр: %s\n", filter_str);
    }
    else
    {
        printf("[C] Фильтр: ВСЕ ПАКЕТЫ\n");
    }

    int sock = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (sock < 0)
    {
        perror("[C] socket");
        return 1;
    }

    struct ifreq ifr_promisc;
    memset(&ifr_promisc, 0, sizeof(ifr_promisc));
    strncpy(ifr_promisc.ifr_name, interface, IFNAMSIZ - 1);

    if (ioctl(sock, SIOCGIFFLAGS, &ifr_promisc) == 0)
    {
        ifr_promisc.ifr_flags |= IFF_PROMISC;
        if (ioctl(sock, SIOCSIFFLAGS, &ifr_promisc) == 0)
        {
            printf("[C] PROMISCUOUS MODE ВКЛЮЧЕН на %s\n", interface);
        }
        else
        {
            perror("[C] Не удалось установить promiscuous mode");
        }
    }
    else
    {
        perror("[C] Не удалось получить флаги интерфейса");
    }

    struct ifreq ifr_index;
    memset(&ifr_index, 0, sizeof(ifr_index));
    strncpy(ifr_index.ifr_name, interface, IFNAMSIZ - 1);

    if (ioctl(sock, SIOCGIFINDEX, &ifr_index) == -1)
    {
        perror("[C] ioctl SIOCGIFINDEX");
        close(sock);
        return 1;
    }

    struct sockaddr_ll sll;
    memset(&sll, 0, sizeof(sll));
    sll.sll_family = AF_PACKET;
    sll.sll_ifindex = ifr_index.ifr_ifindex;
    sll.sll_protocol = htons(ETH_P_ALL);

    if (bind(sock, (struct sockaddr *)&sll, sizeof(sll)) < 0)
    {
        perror("[C] bind");
        close(sock);
        return 1;
    }

    FILE *pcap = fopen(output_file, "wb");
    if (!pcap)
    {
        perror("[C] fopen");
        close(sock);
        return 1;
    }

    unsigned int magic = 0xa1b2c3d4;
    unsigned short version_major = 2;
    unsigned short version_minor = 4;
    unsigned int thiszone = 0;
    unsigned int sigfigs = 0;
    unsigned int snaplen = 65535;
    unsigned int network = 1;

    fwrite(&magic, 4, 1, pcap);
    fwrite(&version_major, 2, 1, pcap);
    fwrite(&version_minor, 2, 1, pcap);
    fwrite(&thiszone, 4, 1, pcap);
    fwrite(&sigfigs, 4, 1, pcap);
    fwrite(&snaplen, 4, 1, pcap);
    fwrite(&network, 4, 1, pcap);

    unsigned char buffer[65536];
    unsigned long packet_count = 0;
    unsigned long filtered_count = 0;

    printf("[C] Начинаю захват пакетов... (Ctrl+C для остановки)\n");
    printf("[C] Детальный вывод пакетов:\n");
    printf("════════════════════════════════════════════════════════════════════════════\n");

    while (running)
    {
        struct sockaddr_ll addr;
        socklen_t addr_len = sizeof(addr);

        int bytes = recvfrom(sock, buffer, sizeof(buffer), 0,
                             (struct sockaddr *)&addr, &addr_len);

        if (bytes <= 0)
        {
            if (bytes < 0)
            {
                perror("[C] recvfrom");
            }
            continue;
        }

        packet_count++;

        if (!packet_matches_filter(buffer, bytes, &fc))
        {
            continue;
        }

        filtered_count++;

        // Детальный вывод каждого пакета, прошедшего фильтр
        print_packet_details(buffer, bytes, filtered_count);

        struct timeval tv;
        gettimeofday(&tv, NULL);

        unsigned int ts_sec = tv.tv_sec;
        unsigned int ts_usec = tv.tv_usec;
        unsigned int incl_len = bytes;
        unsigned int orig_len = bytes;

        fwrite(&ts_sec, 4, 1, pcap);
        fwrite(&ts_usec, 4, 1, pcap);
        fwrite(&incl_len, 4, 1, pcap);
        fwrite(&orig_len, 4, 1, pcap);

        fwrite(buffer, 1, bytes, pcap);
        fflush(pcap);
    }

    printf("\n════════════════════════════════════════════════════════════════════════════\n");
    printf("[C] Завершение работы...\n");
    printf("[C] Всего пакетов: %lu, прошло фильтр: %lu\n", packet_count, filtered_count);

    fclose(pcap);
    close(sock);

    printf("[C] Сниффер остановлен\n");
    return 0;
}