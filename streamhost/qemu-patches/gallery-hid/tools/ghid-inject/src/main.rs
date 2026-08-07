use std::env;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process::ExitCode;

const RECORD_BYTES: usize = 16;
const CLOCK_MONOTONIC_RAW: i32 = 4;

#[repr(C)]
struct Timespec {
    tv_sec: i64,
    tv_nsec: i64,
}

unsafe extern "C" {
    fn clock_gettime(clock_id: i32, tp: *mut Timespec) -> i32;
}

fn monotonic_raw_us() -> Result<u32, String> {
    let mut ts = Timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    if unsafe { clock_gettime(CLOCK_MONOTONIC_RAW, &mut ts) } != 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok((ts.tv_sec as u64 * 1_000_000 + ts.tv_nsec as u64 / 1_000_000) as u32)
}

fn parse_u16(s: &str, what: &str) -> Result<u16, String> {
    let value = if let Some(hex) = s.strip_prefix("0x") {
        u16::from_str_radix(hex, 16)
    } else {
        s.parse()
    };
    value.map_err(|_| format!("invalid {what}: {s}"))
}

fn parse_u8(s: &str, what: &str) -> Result<u8, String> {
    let value = if let Some(hex) = s.strip_prefix("0x") {
        u8::from_str_radix(hex, 16)
    } else {
        s.parse()
    };
    value.map_err(|_| format!("invalid {what}: {s}"))
}

fn put_u16(dst: &mut [u8], value: u16) {
    dst.copy_from_slice(&value.to_le_bytes());
}

fn put_u32(dst: &mut [u8], value: u32) {
    dst.copy_from_slice(&value.to_le_bytes());
}

fn pointer(args: &[String]) -> Result<[u8; RECORD_BYTES], String> {
    if !(args.len() == 3 || args.len() == 5) {
        return Err("pointer requires X Y BUTTONS [WHEEL_V WHEEL_H]".into());
    }
    let x = parse_u16(&args[0], "x")?;
    let y = parse_u16(&args[1], "y")?;
    let buttons = parse_u16(&args[2], "buttons")?;
    if x > 32767 || y > 32767 || buttons & !0x1f != 0 {
        return Err("x/y must be 0..32767 and buttons must fit mask 0x1f".into());
    }
    let wheel_v: i8 = args.get(3).map_or(Ok(0), |s| {
        s.parse()
            .map_err(|_| format!("invalid vertical wheel: {s}"))
    })?;
    let wheel_h: i8 = args.get(4).map_or(Ok(0), |s| {
        s.parse()
            .map_err(|_| format!("invalid horizontal wheel: {s}"))
    })?;
    let mut r = [0u8; RECORD_BYTES];
    r[0] = 0x01;
    put_u16(&mut r[4..6], x);
    put_u16(&mut r[6..8], y);
    put_u16(&mut r[8..10], buttons);
    r[10] = wheel_v as u8;
    r[11] = wheel_h as u8;
    put_u32(&mut r[12..16], monotonic_raw_us()?);
    Ok(r)
}

fn key(args: &[String]) -> Result<[u8; RECORD_BYTES], String> {
    if args.len() < 2 || args.len() > 4 {
        return Err("key requires TOKEN down|up [repeat] [MODIFIERS]".into());
    }
    let token = parse_u16(&args[0], "XT set-1 token")?;
    let mut flags = match args[1].as_str() {
        "down" => 1,
        "up" => 0,
        _ => return Err("key state must be down or up".into()),
    };
    let mut index = 2;
    if args.get(index).is_some_and(|s| s == "repeat") {
        flags |= 2;
        index += 1;
    }
    let modifiers = args
        .get(index)
        .map_or(Ok(0), |s| parse_u16(s, "modifiers"))?;
    if modifiers > 0xff {
        return Err("modifiers must fit mask 0xff".into());
    }
    let mut r = [0u8; RECORD_BYTES];
    r[0] = 0x02;
    r[1] = flags;
    put_u16(&mut r[4..6], token);
    put_u16(&mut r[6..8], modifiers);
    put_u32(&mut r[12..16], monotonic_raw_us()?);
    Ok(r)
}

fn release_all(args: &[String]) -> Result<[u8; RECORD_BYTES], String> {
    if args.len() > 1 {
        return Err("release-all accepts at most FLAGS".into());
    }
    let flags = args.first().map_or(Ok(0), |s| parse_u8(s, "flags"))?;
    if flags & !0x07 != 0 {
        return Err("release-all flags must fit mask 0x07".into());
    }
    let mut r = [0u8; RECORD_BYTES];
    r[0] = 0x03;
    r[1] = flags;
    put_u32(&mut r[12..16], monotonic_raw_us()?);
    Ok(r)
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        return Err(format!(
            "usage: {} SOCKET pointer X Y BUTTONS [WHEEL_V WHEEL_H]\n       \
             {} SOCKET key TOKEN down|up [repeat] [MODIFIERS]\n       \
             {} SOCKET release-all [FLAGS]",
            args[0], args[0], args[0]
        ));
    }
    let record = match args[2].as_str() {
        "pointer" => pointer(&args[3..])?,
        "key" => key(&args[3..])?,
        "release-all" => release_all(&args[3..])?,
        verb => return Err(format!("unknown verb: {verb}")),
    };

    let mut stream = UnixStream::connect(&args[1]).map_err(|e| format!("connect: {e}"))?;
    let mut hello = [0u8; RECORD_BYTES];
    hello[0..4].copy_from_slice(b"GHIN");
    put_u16(&mut hello[4..6], 1);
    put_u16(&mut hello[6..8], 0);
    put_u16(&mut hello[8..10], RECORD_BYTES as u16);
    stream
        .write_all(&hello)
        .map_err(|e| format!("write hello: {e}"))?;
    let mut reply = [0u8; RECORD_BYTES];
    stream
        .read_exact(&mut reply)
        .map_err(|e| format!("read GHOK: {e}"))?;
    if &reply[0..4] != b"GHOK" || u16::from_le_bytes([reply[4], reply[5]]) != 1 {
        return Err("backend returned an incompatible handshake".into());
    }
    stream
        .write_all(&record)
        .map_err(|e| format!("write record: {e}"))?;
    let epoch = u32::from_le_bytes(reply[8..12].try_into().unwrap());
    let status = u32::from_le_bytes(reply[12..16].try_into().unwrap());
    println!("GHOK epoch={epoch} status=0x{status:08x} sent={}", args[2]);
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("ghid-inject: {error}");
            ExitCode::FAILURE
        }
    }
}
