use std::io::{self, BufRead, Read};
use std::net::{Ipv4Addr, UdpSocket};

fn native_desktop() -> bool {
    #[cfg(feature = "lan-bench")]
    { std::env::var("SESAME_PHYSICAL_PORTS").as_deref() == Ok("1") }
    #[cfg(not(feature = "lan-bench"))]
    { false }
}

fn direct_main() -> Result<(), &'static str> {
    let mut source = io::BufReader::new(io::stdin().take(640));
    let mut read = || {
        let mut line = String::new();
        source.read_line(&mut line).ok().filter(|n| *n > 0)?;
        Some(line.trim().to_owned())
    };
    let parse = |s: String| -> Option<[u8;32]> {
        if s.len() != 64 || !s.bytes().all(|b| b.is_ascii_hexdigit()) { return None; }
        let mut out = [0;32];
        for (i, v) in out.iter_mut().enumerate() {
            *v = u8::from_str_radix(&s[i*2..i*2+2],16).ok()?;
        }
        Some(out)
    };
    let private = read().and_then(parse).ok_or("media_direct_config_invalid")?;
    let ticket = read().and_then(parse).ok_or("media_direct_config_invalid")?;
    let observer = read().as_deref().and_then(sesame_wan_peer::observer_endpoint)
        .ok_or("media_observer_invalid")?;
    let sock = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).map_err(|_| "media_direct_bind_failed")?;
    sesame_wan_peer::media::announce(&sock, &ticket, observer).map_err(|_| "media_direct_announce_failed")?;
    println!("stage=host_media_direct_announced");
    if std::env::args().nth(2).as_deref() == Some("--mapping-diagnostics") {
        let ok = sesame_wan_peer::media::announce_mapping(&sock, &ticket, observer).is_ok();
        println!("direct_mapping_probe_sent={}", u32::from(ok));
    }
    let remote = read().ok_or("media_direct_config_incomplete")?;
    let key = read().ok_or("media_direct_config_incomplete")?;
    let rate = read().and_then(|s| s.parse().ok()).ok_or("media_direct_config_incomplete")?;
    let report = sesame_wan_peer::media::direct_host(sock, &remote, private, &key, rate, native_desktop())?;
    println!("{report}");
    Ok(())
}

fn main() {
    if std::env::args().skip(1).eq(["--lan", "--physical", "--managed"].into_iter().map(String::from)) {
        #[cfg(feature="companion-wan")]
        if let Err(reason)=managed_lan() { println!("stage={reason}"); }
        #[cfg(not(feature="companion-wan"))]
        println!("stage=managed_lan_not_built");
        return;
    }
    #[cfg(feature = "companion-wan")]
    if std::env::args().nth(1).as_deref() == Some("--companion-wan") {
        companion_main();
        return;
    }
    #[cfg(feature = "lan-bench")]
    if std::env::args().nth(1).as_deref() == Some("--lan") {
        let native_desktop = std::env::args().nth(2).as_deref() == Some("--physical");
        let mut input = String::new();
        if io::stdin().take(400).read_to_string(&mut input).is_err() {
            println!("stage=lan_config_unreadable");
            return;
        }
        let parts: Vec<_> = input.lines().collect();
        let result = match parts.as_slice() {
            [local, remote, secret, public, rate] => rate.parse().map_err(|_| "lan_config_invalid")
                .and_then(|kbps| sesame_wan_peer::media::lan_host(local, remote, secret, public, kbps, native_desktop)),
            _ => Err("lan_config_invalid"),
        };
        match result { Ok(s) => println!("{s}"), Err(e) => println!("stage={e}") }
        return;
    }
    if std::env::args().nth(1).as_deref() == Some("--direct") {
        if let Err(error) = direct_main() { println!("stage={error}"); }
        return;
    }
    let mut input = String::new();
    if io::stdin().take(1024).read_to_string(&mut input).is_err() {
        println!("stage=host_config_unreadable");
        return;
    }
    let Some(cfg) = sesame_wan_peer::params(&input) else {
        println!("stage=host_config_invalid");
        return;
    };
    drop(input);
    if std::env::args().nth(1).as_deref() == Some("--media") {
        let rate = std::env::args().nth(2).and_then(|s| s.parse::<u32>().ok());
        let Some(rate) = rate else {
            println!("stage=media_wire_budget_required");
            return;
        };
        match sesame_wan_peer::media::host(cfg, rate, native_desktop()) {
            Ok(s) => println!("{s}"),
            Err(e) => println!("stage={e}"),
        }
        return;
    }
    println!("stage=host_media_mode_required");
}

#[cfg(feature="companion-wan")]
fn managed_lan() -> Result<(), &'static str> {
    use std::sync::{Arc, atomic::{AtomicBool,Ordering}};
    use zeroize::Zeroizing;
    // Private inherited pipe only. Closing it ends this lease and lets the
    // numeric trace writer commit its completeness marker before process exit.
    let mut reader=io::BufReader::new(io::stdin().take(401));
    let mut fields=Zeroizing::new(Vec::<String>::new());
    for _ in 0..5 {
        let mut field=Zeroizing::new(String::new());
        if reader.read_line(&mut field).map_err(|_|"lan_config_unreadable")?==0 || !field.ends_with('\n') {
            return Err("lan_config_invalid");
        }
        fields.push(field.trim_end().to_owned());
    }
    let stop=Arc::new(AtomicBool::new(false));
    let watch=stop.clone();
    std::thread::Builder::new().name("companion-lease".into()).spawn(move || {
        reader.get_mut().set_limit(5000);
        let mut byte=[0;1];
        while matches!(reader.read(&mut byte),Ok(1)) && byte[0]==b'L' {
            sesame_wan_peer::media::sesame_companion_live_renew();
        }
        watch.store(true,Ordering::Release);
    }).map_err(|_|"lan_lease_watch_failed")?;
    let rate=fields[4].parse().map_err(|_|"lan_config_invalid")?;
    let report=sesame_wan_peer::media::lan_host_until(&fields[0],&fields[1],&fields[2],&fields[3],rate,true,
        ||stop.load(Ordering::Acquire))?;
    println!("{report}");
    Ok(())
}

#[cfg(feature = "companion-wan")]
fn companion_main() {
    use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
    use zeroize::Zeroizing;
    let mut input = io::BufReader::new(io::stdin().take(1024));
    let mut line = || {
        let mut result = String::new();
        (input.read_line(&mut result).ok()? > 0).then(|| result.trim().to_owned())
    };
    let Some(broker) = line() else { return; };
    let Some(encoded) = line().map(Zeroizing::new) else { return; };
    let Some(port) = line().and_then(|p| p.parse::<u16>().ok()) else { return; };
    let mut root = Zeroizing::new([0;32]);
    if encoded.len() != 64 || !encoded.bytes().all(|b| b.is_ascii_hexdigit()) { return; }
    for (i, n) in root.iter_mut().enumerate() {
        let Ok(x) = u8::from_str_radix(&encoded[i*2..i*2+2],16) else { return; };
        *n = x;
    }
    drop(encoded);
    let stop = Arc::new(AtomicBool::new(false));
    let reader = stop.clone();
    std::thread::spawn(move || {
        input.get_mut().set_limit(5000);
        let mut byte=[0;1];
        while matches!(input.read(&mut byte),Ok(1)) && byte[0]==b'L' {
            sesame_wan_peer::media::sesame_companion_live_renew();
        }
        reader.store(true,Ordering::Relaxed);
    });
    let silent = std::env::args().nth(2).as_deref() == Some("--test-silent-direct");
    match sesame_wan_peer::companion_wan::windows(&broker,&root,port,silent,|| stop.load(Ordering::Relaxed)) {
        Ok(report) => println!("{report}"),
        Err(stage) => println!("stage={stage}"),
    }
}
