/*
 * mdns-announce -- a minimal mDNS responder: answer A queries for
 * <name>.local and announce that record unsolicited at startup.
 *
 *   mdns-announce <name> <ipv4> [-v]
 *
 * Written for the IWE 3000N because the box has no room for avahi and the
 * small third-party responders bind through the routing table -- in AP mode
 * this board has no default route, so they never send. Everything here is
 * pinned to the interface that owns <ipv4>.
 *
 * Scope on purpose: A records for one name. No services, no probing, no
 * conflict resolution. That is all "ssh root@iwe3000n.local" needs.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <errno.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#define MDNS_ADDR "224.0.0.251"
#define MDNS_PORT 5353
#define TTL_SECS  120

static int verbose;
#define LOGV(...) do { if (verbose) { fprintf(stderr, __VA_ARGS__); fflush(stderr); } } while (0)

/* "iwe3000n.local" -> "\x08iwe3000n\x05local\x00" */
static int encode_name(const char *name, unsigned char *out, size_t outsz)
{
	size_t o = 0;
	const char *p = name;
	while (*p) {
		const char *dot = strchr(p, '.');
		size_t len = dot ? (size_t)(dot - p) : strlen(p);
		if (len == 0 || len > 63 || o + len + 1 >= outsz)
			return -1;
		out[o++] = (unsigned char)len;
		memcpy(out + o, p, len);
		o += len;
		if (!dot)
			break;
		p = dot + 1;
	}
	if (o + 1 > outsz)
		return -1;
	out[o++] = 0;
	return (int)o;
}

/* Read a (possibly compressed) name at off into dotted form. Returns the
 * offset just past the name in the packet, or -1. */
static int read_name(const unsigned char *pkt, int len, int off, char *out, size_t outsz)
{
	int jumped = 0, orig_end = -1, guard = 0;
	size_t o = 0;
	while (off >= 0 && off < len && guard++ < 64) {
		unsigned char l = pkt[off];
		if ((l & 0xc0) == 0xc0) {			/* pointer */
			if (off + 1 >= len)
				return -1;
			if (!jumped)
				orig_end = off + 2;
			off = ((l & 0x3f) << 8) | pkt[off + 1];
			jumped = 1;
			continue;
		}
		off++;
		if (l == 0)
			break;
		if (off + l > len || o + l + 1 >= outsz)
			return -1;
		if (o)
			out[o++] = '.';
		memcpy(out + o, pkt + off, l);
		o += l;
		off += l;
	}
	out[o] = 0;
	return jumped ? orig_end : off;
}

/* header(12) + name + type/class + ttl + rdlen + 4 bytes of address */
static int build_answer(unsigned char *buf, size_t bufsz, const unsigned char *qname,
			int qnlen, uint32_t ip, int is_response_to_query)
{
	if (bufsz < (size_t)(12 + qnlen + 14))
		return -1;
	memset(buf, 0, 12);
	buf[2] = 0x84;					/* QR=1, AA=1 */
	buf[7] = 1;					/* ANCOUNT=1 */
	int o = 12;
	memcpy(buf + o, qname, qnlen); o += qnlen;
	buf[o++] = 0; buf[o++] = 1;			/* TYPE  A */
	buf[o++] = 0x80; buf[o++] = 1;			/* CLASS IN | cache-flush */
	buf[o++] = 0; buf[o++] = 0;
	buf[o++] = (TTL_SECS >> 8) & 0xff; buf[o++] = TTL_SECS & 0xff;
	buf[o++] = 0; buf[o++] = 4;			/* RDLENGTH */
	memcpy(buf + o, &ip, 4); o += 4;
	(void)is_response_to_query;
	return o;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: %s <name> <ipv4> [-v]\n", argv[0]);
		return 2;
	}
	const char *shortname = argv[1];
	uint32_t ip = inet_addr(argv[2]);
	if (ip == INADDR_NONE) {
		fprintf(stderr, "bad address %s\n", argv[2]);
		return 2;
	}
	for (int i = 3; i < argc; i++)
		if (!strcmp(argv[i], "-v"))
			verbose = 1;

	char fqdn[256];
	snprintf(fqdn, sizeof fqdn, "%s.local", shortname);
	unsigned char qname[256];
	int qnlen = encode_name(fqdn, qname, sizeof qname);
	if (qnlen < 0) {
		fprintf(stderr, "name too long\n");
		return 2;
	}

	int sd = socket(AF_INET, SOCK_DGRAM, 0);
	if (sd < 0) { perror("socket"); return 1; }
	int on = 1;
	if (setsockopt(sd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on) < 0)
		perror("SO_REUSEADDR");
#ifdef SO_REUSEPORT
	setsockopt(sd, SOL_SOCKET, SO_REUSEPORT, &on, sizeof on);
#endif
	struct sockaddr_in me;
	memset(&me, 0, sizeof me);
	me.sin_family = AF_INET;
	me.sin_addr.s_addr = htonl(INADDR_ANY);
	me.sin_port = htons(MDNS_PORT);
	if (bind(sd, (struct sockaddr *)&me, sizeof me) < 0) { perror("bind"); return 1; }

	/* Pin everything to the interface that owns our address: this board has
	 * no default route in AP mode, so INADDR_ANY selects nothing. */
	struct ip_mreq mreq;
	memset(&mreq, 0, sizeof mreq);
	mreq.imr_multiaddr.s_addr = inet_addr(MDNS_ADDR);
	mreq.imr_interface.s_addr = ip;
	if (setsockopt(sd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof mreq) < 0)
		perror("IP_ADD_MEMBERSHIP");
	struct in_addr mif = { .s_addr = ip };
	if (setsockopt(sd, IPPROTO_IP, IP_MULTICAST_IF, &mif, sizeof mif) < 0)
		perror("IP_MULTICAST_IF");
	unsigned char ttl = 255, loop = 0;
	setsockopt(sd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof ttl);
	setsockopt(sd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, sizeof loop);

	struct sockaddr_in group;
	memset(&group, 0, sizeof group);
	group.sin_family = AF_INET;
	group.sin_addr.s_addr = inet_addr(MDNS_ADDR);
	group.sin_port = htons(MDNS_PORT);

	unsigned char out[512];
	int outlen = build_answer(out, sizeof out, qname, qnlen, ip, 0);
	if (outlen < 0) { fprintf(stderr, "answer too big\n"); return 1; }

	fprintf(stderr, "mdns-announce: %s -> %s\n", fqdn, argv[2]);
	fflush(stderr);

	/* Unsolicited announcements so caches learn us without asking. */
	for (int i = 0; i < 3; i++) {
		if (sendto(sd, out, outlen, 0, (struct sockaddr *)&group, sizeof group) < 0)
			perror("announce sendto");
		sleep(1);
	}

	for (;;) {
		unsigned char pkt[1500];
		struct sockaddr_in from;
		socklen_t fromlen = sizeof from;
		ssize_t n = recvfrom(sd, pkt, sizeof pkt, 0, (struct sockaddr *)&from, &fromlen);
		if (n < 12) {
			if (n < 0 && errno != EINTR)
				perror("recvfrom");
			continue;
		}
		if (pkt[2] & 0x80)			/* a response, not a query */
			continue;
		int qdcount = (pkt[4] << 8) | pkt[5];
		int off = 12, hit = 0;
		for (int q = 0; q < qdcount && off > 0 && off < n; q++) {
			char qn[256];
			int next = read_name(pkt, (int)n, off, qn, sizeof qn);
			if (next < 0 || next + 4 > n)
				break;
			int qtype = (pkt[next] << 8) | pkt[next + 1];
			off = next + 4;
			LOGV("query for '%s' type %d from %s\n", qn, qtype, inet_ntoa(from.sin_addr));
			if ((qtype == 1 || qtype == 255) && !strcasecmp(qn, fqdn))
				hit = 1;
		}
		if (!hit)
			continue;
		if (sendto(sd, out, outlen, 0, (struct sockaddr *)&group, sizeof group) < 0)
			perror("reply sendto");
		else
			LOGV("answered %s with %s\n", fqdn, argv[2]);
	}
	return 0;
}
