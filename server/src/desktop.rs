//! guacd handshake. The target is pinned by the existing Relay ticket, never
//! accepted from a browser's Guacamole connect instruction.
use serde::Deserialize;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};
use zeroize::Zeroize;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DesktopHello {
    protocol: String,
    #[serde(default)]
    certificate_sha256: Option<String>,
    #[serde(default)]
    username: String,
    #[serde(default)]
    password: String,
    #[serde(default = "default_width")]
    width: u16,
    #[serde(default = "default_height")]
    height: u16,
}
fn default_width() -> u16 {
    1280
}
fn default_height() -> u16 {
    800
}
impl Drop for DesktopHello {
    fn drop(&mut self) {
        self.password.zeroize();
        self.username.zeroize();
    }
}

pub(crate) fn encode(values: &[&str]) -> String {
    values
        .iter()
        .map(|v| format!("{}.{}", v.chars().count(), v))
        .collect::<Vec<_>>()
        .join(",")
        + ";"
}

/// Returns one complete instruction and consumed UTF-8 byte count. Fragmented
/// code points and arbitrary TCP packet boundaries are supported. Runs in
/// time linear in the consumed instruction (only the bytes of this
/// instruction are inspected and UTF-8 validated), so parsing a message of
/// many instructions stays linear overall.
pub(crate) fn parse(bytes: &[u8]) -> Result<Option<(Vec<String>, usize)>, ()> {
    if bytes.len() > 1024 * 1024 {
        return Err(());
    }
    let mut pos = 0;
    let mut values = Vec::new();
    loop {
        let rest = &bytes[pos..];
        let Some(dot) = rest.iter().take(8).position(|b| *b == b'.') else {
            if rest.len() > 7 || !rest.iter().all(u8::is_ascii_digit) {
                return Err(());
            }
            return Ok(None);
        };
        if dot == 0 || dot > 7 || !rest[..dot].iter().all(u8::is_ascii_digit) {
            return Err(());
        }
        let length: usize = std::str::from_utf8(&rest[..dot])
            .map_err(|_| ())?
            .parse()
            .map_err(|_| ())?;
        if length > 1024 * 1024 {
            return Err(());
        }
        let start = pos + dot + 1;
        let mut end = start;
        for _ in 0..length {
            let Some(&lead) = bytes.get(end) else {
                return Ok(None);
            };
            let width = match lead {
                0x00..=0x7F => 1,
                0xC2..=0xDF => 2,
                0xE0..=0xEF => 3,
                0xF0..=0xF4 => 4,
                _ => return Err(()),
            };
            let available = bytes.len().min(end + width);
            if !bytes[end + 1..available].iter().all(|b| (0x80..=0xBF).contains(b)) {
                return Err(());
            }
            if end + width > bytes.len() {
                // A code point split across packets.
                return Ok(None);
            }
            end += width;
        }
        // Full validation (overlongs, surrogates) of exactly this value.
        let value = std::str::from_utf8(&bytes[start..end]).map_err(|_| ())?;
        if end == bytes.len() {
            return Ok(None);
        }
        values.push(value.to_owned());
        if values.len() > 256 {
            return Err(());
        }
        match bytes[end] {
            b';' => return Ok(Some((values, end + 1))),
            b',' => pos = end + 1,
            _ => return Err(()),
        }
    }
}

pub(crate) fn valid_input(bytes: &[u8]) -> bool {
    let mut rest = bytes;
    while !rest.is_empty() {
        let Ok(Some((v, count))) = parse(rest) else {
            return false;
        };
        let numeric = |i: usize, max: u64| {
            v.get(i)
                .and_then(|s| s.parse::<u64>().ok())
                .is_some_and(|n| n <= max)
        };
        let allowed = match v[0].as_str() {
            "sync" => (v.len() == 2 || v.len() == 3) && numeric(1, u64::MAX),
            "key" => v.len() == 3 && numeric(1, u32::MAX as u64) && numeric(2, 1),
            "mouse" => {
                (v.len() == 4 || v.len() == 5)
                    && numeric(1, 8192)
                    && numeric(2, 8192)
                    && numeric(3, 31)
            }
            "size" => v.len() == 3 && numeric(1, 4096) && numeric(2, 4096),
            "ack" => v.len() == 4 && numeric(1, u32::MAX as u64) && numeric(3, u16::MAX as u64),
            "clipboard" => v.len() == 3 && numeric(1, 65535) && v[2] == "text/plain",
            "blob" => v.len() == 3 && numeric(1, 65535) && v[2].len() <= 49152,
            "end" => v.len() == 2 && numeric(1, 65535),
            "disconnect" | "nop" => v.len() == 1,
            _ => false,
        };
        if !allowed {
            return false;
        }
        rest = &rest[count..];
    }
    !bytes.is_empty()
}

pub(crate) async fn handshake(
    tcp: &mut TcpStream,
    hello: DesktopHello,
    ip: std::net::IpAddr,
    port: u16,
) -> Result<(), ()> {
    if hello.certificate_sha256.as_ref().is_some_and(|pin| {
        hello.protocol != "rdp" || pin.len() != 64 || !pin.bytes().all(|b| b.is_ascii_hexdigit())
    }) {
        return Err(());
    }
    if !matches!(hello.protocol.as_str(), "rdp" | "vnc")
        || hello.username.len() > 256
        || hello.password.len() > 65536
        || hello.username.contains('\0')
        || hello.password.contains('\0')
        || !(320..=4096).contains(&hello.width)
        || !(200..=4096).contains(&hello.height)
    {
        return Err(());
    }
    tcp.write_all(encode(&["select", &hello.protocol]).as_bytes())
        .await
        .map_err(|_| ())?;
    let mut buffer = Vec::new();
    let args = loop {
        // Reading one byte prevents consuming the first display instruction.
        // Only the small args handshake uses this path, under a fixed timeout.
        buffer.push(tcp.read_u8().await.map_err(|_| ())?);
        if buffer.len() > 16384 {
            return Err(());
        }
        if let Some((v, _)) = parse(&buffer)? {
            break v;
        }
    };
    if hello.certificate_sha256.is_some() && !args.iter().any(|arg| arg == "cert-fingerprints") {
        return Err(());
    }
    if args.first().map(String::as_str) != Some("args") {
        return Err(());
    }
    for fields in [
        vec![
            "size".to_owned(),
            hello.width.to_string(),
            hello.height.to_string(),
            "96".to_owned(),
        ],
        vec!["audio".to_owned()],
        vec!["video".to_owned()],
        vec![
            "image".to_owned(),
            "image/png".to_owned(),
            "image/jpeg".to_owned(),
        ],
    ] {
        tcp.write_all(encode(&fields.iter().map(String::as_str).collect::<Vec<_>>()).as_bytes())
            .await
            .map_err(|_| ())?;
    }
    let mut values = vec!["connect".to_owned()];
    for arg in &args[1..] {
        values.push(match arg.as_str() {
            v if v.starts_with("VERSION_") => "VERSION_1_0_0".to_owned(),
            "hostname" => ip.to_string(),
            "port" => port.to_string(),
            "cert-fingerprints" => hello
                .certificate_sha256
                .as_ref()
                .map(|pin| {
                    format!(
                        "sha256:{}",
                        pin.as_bytes()
                            .chunks(2)
                            .map(|b| std::str::from_utf8(b).unwrap_or(""))
                            .collect::<Vec<_>>()
                            .join(":")
                    )
                })
                .unwrap_or_default(),
            "username" => hello.username.clone(),
            "password" => hello.password.clone(),
            "width" => hello.width.to_string(),
            "height" => hello.height.to_string(),
            "dpi" => "96".to_owned(),
            "security" => "any".to_owned(),
            "resize-method" => "display-update".to_owned(),
            "force-lossless" | "disable-audio" | "disable-gfx" => "true".to_owned(),
            "enable-drive" | "enable-printing" | "enable-sftp" | "ignore-cert" => {
                "false".to_owned()
            }
            _ => String::new(),
        });
    }
    let mut instruction = encode(&values.iter().map(String::as_str).collect::<Vec<_>>());
    let result = tcp.write_all(instruction.as_bytes()).await.map_err(|_| ());
    instruction.zeroize();
    for v in &mut values {
        v.zeroize();
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn framing_handles_unicode_and_fragments() {
        let frame = encode(&["clipboard", "中😀", "a,b;c"]);
        for i in 0..frame.len() {
            assert_eq!(parse(&frame.as_bytes()[..i]), Ok(None));
        }
        assert_eq!(
            parse(frame.as_bytes()),
            Ok(Some((
                vec!["clipboard".into(), "中😀".into(), "a,b;c".into()],
                frame.len()
            )))
        );
        for bad in ["x.key;", "-1.x;", "10000000.x;", "1.x!"] {
            assert!(parse(bad.as_bytes()).is_err());
        }
    }
    #[test]
    fn input_cannot_retarget_or_open_files() {
        assert!(valid_input(encode(&["key", "65293", "1"]).as_bytes()));
        assert!(valid_input(encode(&["mouse", "12", "20", "1"]).as_bytes()));
        for op in ["select", "connect", "argv", "file", "pipe", "audio"] {
            assert!(!valid_input(encode(&[op, "rdp"]).as_bytes()));
        }
        assert!(!valid_input(b"3.key,1.1,1.1"));
        assert!(!valid_input(encode(&["size", "9000", "500"]).as_bytes()));
    }
    #[test]
    fn parsing_many_instructions_is_linear_and_rejects_bad_utf8() {
        let many = encode(&["key", "65", "1"]).repeat(6000);
        let started = std::time::Instant::now();
        assert!(valid_input(many.as_bytes()));
        assert!(started.elapsed() < std::time::Duration::from_millis(500));
        assert!(parse(b"2.\xC3\x28;").is_err(), "invalid continuation");
        assert!(parse(b"1.\xED\xA0\x80;").is_err(), "surrogate");
        assert!(parse(b"1.\xC0\x80;").is_err(), "overlong");
        assert_eq!(parse(b"1.\xE4\xB8"), Ok(None), "split code point");
    }
}
