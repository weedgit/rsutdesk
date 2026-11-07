//! Team edition policy: LAN-only, no passwords, access decided by an allowed-IP list.
//!
//! This file holds only pure logic (no I/O, no config access) so it can be unit-tested
//! without the native media stack the main crate needs. The main crate wires it in.

use std::net::IpAddr;

/// This build works only on the local network. There are no ID/relay servers, no accounts,
/// no web console and no auto-update. Connections go straight to `IP:21118`.
pub const LAN_ONLY: bool = true;

/// Option key holding the allowed IP list. It is the same key the stock "IP whitelist"
/// setting writes, so the existing settings dialog keeps working.
pub const OPTION_ALLOWED_IPS: &str = "whitelist";

/// Entries that allow every address. Only meant for testing.
const ALLOW_ALL: [&str; 2] = ["*", "0.0.0.0"];

/// Splits a stored list. Accepts commas, semicolons, spaces and newlines as separators.
pub fn parse_allowed_list(s: &str) -> Vec<String> {
    s.split(|c: char| c == ',' || c == ';' || c.is_whitespace())
        .map(|x| x.trim())
        .filter(|x| !x.is_empty())
        .map(|x| x.to_owned())
        .collect()
}

/// Joins entries back into the stored (comma separated) form, dropping duplicates.
pub fn join_allowed_list(entries: &[String]) -> String {
    let mut out: Vec<&str> = Vec::new();
    for e in entries {
        let e = e.trim();
        if !e.is_empty() && !out.contains(&e) {
            out.push(e);
        }
    }
    out.join(",")
}

/// True if `entry` is `*`, `0.0.0.0`, an IP address, or a CIDR range like `192.168.1.0/24`.
pub fn is_valid_entry(entry: &str) -> bool {
    let entry = entry.trim();
    ALLOW_ALL.contains(&entry) || parse_cidr(entry).is_some()
}

/// Returns the entries of `s` that are not valid, so a UI can point at them.
pub fn invalid_entries(s: &str) -> Vec<String> {
    parse_allowed_list(s)
        .into_iter()
        .filter(|x| !is_valid_entry(x))
        .collect()
}

/// Decides whether a peer address may connect.
///
/// An empty list allows nobody: a desktop accepts connections only after someone adds the
/// controlling machines' addresses to it.
pub fn is_ip_allowed(list: &[String], ip: IpAddr) -> bool {
    let ip = canonical(ip);
    list.iter().any(|entry| {
        let entry = entry.trim();
        if ALLOW_ALL.contains(&entry) {
            return true;
        }
        match parse_cidr(entry) {
            Some((net, prefix)) => contains(net, prefix, ip),
            None => false,
        }
    })
}

/// IPv4 clients reach a dual-stack listener as `::ffff:a.b.c.d`. Compare them as IPv4.
fn canonical(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => IpAddr::V4(v4),
            None => IpAddr::V6(v6),
        },
        v4 => v4,
    }
}

fn parse_cidr(entry: &str) -> Option<(IpAddr, u8)> {
    let (addr, prefix) = match entry.split_once('/') {
        Some((a, p)) => (a, Some(p)),
        None => (entry, None),
    };
    let addr: IpAddr = addr.trim().parse().ok()?;
    let addr = canonical(addr);
    let max = if addr.is_ipv4() { 32 } else { 128 };
    let prefix = match prefix {
        Some(p) => {
            let p: u8 = p.trim().parse().ok()?;
            if p > max {
                return None;
            }
            p
        }
        None => max,
    };
    Some((addr, prefix))
}

fn contains(net: IpAddr, prefix: u8, ip: IpAddr) -> bool {
    match (net, ip) {
        (IpAddr::V4(n), IpAddr::V4(i)) => {
            let mask = if prefix == 0 { 0 } else { u32::MAX << (32 - prefix) };
            (u32::from(n) & mask) == (u32::from(i) & mask)
        }
        (IpAddr::V6(n), IpAddr::V6(i)) => {
            let mask = if prefix == 0 { 0 } else { u128::MAX << (128 - prefix) };
            (u128::from(n) & mask) == (u128::from(i) & mask)
        }
        _ => false,
    }
}

/// Whether `ip` is on the local network: a private (RFC 1918) or link-local IPv4 address, a
/// unique-local or link-local IPv6 address, or loopback. The team edition talks to nothing else,
/// in either direction.
pub fn is_lan_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_private() || v4.is_link_local() || v4.is_loopback(),
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return is_lan_ip(IpAddr::V4(v4));
            }
            let first = v6.segments()[0];
            v6.is_loopback()
                || (first & 0xfe00) == 0xfc00 // fc00::/7 unique local
                || (first & 0xffc0) == 0xfe80 // fe80::/10 link local
        }
    }
}

/// The error shown when something tries to reach an address outside the local network.
pub const NOT_LAN_ERROR: &str =
    "Team edition works on the local network only; this address is not a LAN address.";

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    fn list(s: &str) -> Vec<String> {
        parse_allowed_list(s)
    }

    #[test]
    fn empty_list_allows_nobody() {
        assert!(!is_ip_allowed(&[], ip("192.168.1.10")));
        assert!(!is_ip_allowed(&list(" , \n"), ip("127.0.0.1")));
    }

    #[test]
    fn exact_ip_and_cidr() {
        let l = list("192.168.1.10, 10.0.0.0/8");
        assert!(is_ip_allowed(&l, ip("192.168.1.10")));
        assert!(!is_ip_allowed(&l, ip("192.168.1.11")));
        assert!(is_ip_allowed(&l, ip("10.20.30.40")));
        assert!(!is_ip_allowed(&l, ip("11.0.0.1")));
    }

    #[test]
    fn ipv4_mapped_peers_match_ipv4_entries() {
        let l = list("192.168.1.0/24");
        assert!(is_ip_allowed(&l, ip("::ffff:192.168.1.77")));
        assert!(!is_ip_allowed(&l, ip("::ffff:192.168.2.77")));
    }

    #[test]
    fn ipv6_ranges() {
        let l = list("fd00::/8");
        assert!(is_ip_allowed(&l, ip("fd12::1")));
        assert!(!is_ip_allowed(&l, ip("fe80::1")));
    }

    #[test]
    fn allow_all_entries() {
        assert!(is_ip_allowed(&list("*"), ip("8.8.8.8")));
        assert!(is_ip_allowed(&list("0.0.0.0"), ip("fe80::1")));
    }

    #[test]
    fn separators_and_validation() {
        assert_eq!(
            list("1.1.1.1;2.2.2.2\n3.3.3.0/24  4.4.4.4"),
            vec!["1.1.1.1", "2.2.2.2", "3.3.3.0/24", "4.4.4.4"]
        );
        assert!(is_valid_entry("192.168.0.0/16"));
        assert!(!is_valid_entry("192.168.0.0/33"));
        assert!(!is_valid_entry("my-pc"));
        assert_eq!(invalid_entries("1.1.1.1, bad, 2.2.2.2/40"), vec!["bad", "2.2.2.2/40"]);
        assert_eq!(
            join_allowed_list(&list("1.1.1.1, 1.1.1.1, 2.2.2.2")),
            "1.1.1.1,2.2.2.2"
        );
    }

    #[test]
    fn zero_prefix_matches_family_only() {
        let l = list("0.0.0.0/0");
        assert!(is_ip_allowed(&l, ip("203.0.113.5")));
        assert!(!is_ip_allowed(&l, ip("2001:db8::1")));
    }

    #[test]
    fn lan_ips() {
        for s in [
            "10.0.0.1",
            "172.16.5.4",
            "172.31.255.255",
            "192.168.1.20",
            "169.254.3.3",
            "127.0.0.1",
            "::1",
            "fd12:3456::1",
            "fe80::1",
            "::ffff:192.168.1.5",
        ] {
            assert!(is_lan_ip(ip(s)), "{} should be LAN", s);
        }
        for s in [
            "8.8.8.8",
            "172.32.0.1",
            "100.64.0.1",
            "203.0.113.5",
            "0.0.0.0",
            "2001:db8::1",
            "2606:4700::1111",
            "::ffff:8.8.8.8",
        ] {
            assert!(!is_lan_ip(ip(s)), "{} should not be LAN", s);
        }
    }
}
