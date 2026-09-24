//! The little JSON the seat needs: a reader for the compositor's answers
//! and a string quoter for the one reply the helper writes as JSON.
//!
//! Hand-written rather than a serde stack: the inputs are two small,
//! fixed-shape documents (`j/devices`, `j/getoption`), the output is one
//! object built by hand, and the helper's dependency set is part of what
//! keeps a process that can type into any window auditable.

/// A parsed JSON value. Numbers keep `f64`, which is exact for every
/// integer the compositor reports (group indices, flags).
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

/// Nesting deeper than this is refused rather than recursed into: the
/// documents read here are three levels deep, and an unbounded descent is
/// a stack the input controls.
const MAX_DEPTH: usize = 16;

impl Json {
    pub(crate) fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(fields) => fields.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub(crate) fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(text) => Some(text),
            _ => None,
        }
    }

    pub(crate) fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(value) => Some(*value),
            _ => None,
        }
    }

    /// A non-negative integer that fits a `u32`; anything else (fractions,
    /// negatives, huge values) is not an index.
    pub(crate) fn as_u32(&self) -> Option<u32> {
        match self {
            Json::Num(n) if *n >= 0.0 && n.fract() == 0.0 && *n <= u32::MAX as f64 => {
                Some(*n as u32)
            }
            _ => None,
        }
    }

    pub(crate) fn as_array(&self) -> Option<&[Json]> {
        match self {
            Json::Arr(items) => Some(items),
            _ => None,
        }
    }
}

/// Parses one complete JSON document. `None` for anything malformed,
/// including trailing garbage after the value.
pub(crate) fn parse(text: &str) -> Option<Json> {
    let mut reader = Reader {
        bytes: text.as_bytes(),
        at: 0,
    };
    let value = reader.value(0)?;
    reader.skip_ws();
    (reader.at == reader.bytes.len()).then_some(value)
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn skip_ws(&mut self) {
        while matches!(self.bytes.get(self.at), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.at += 1;
        }
    }

    fn eat(&mut self, byte: u8) -> Option<()> {
        self.skip_ws();
        (self.bytes.get(self.at) == Some(&byte)).then(|| self.at += 1)
    }

    fn literal(&mut self, word: &str, value: Json) -> Option<Json> {
        let end = self.at.checked_add(word.len())?;
        (self.bytes.get(self.at..end)? == word.as_bytes()).then(|| {
            self.at = end;
            value
        })
    }

    fn value(&mut self, depth: usize) -> Option<Json> {
        if depth > MAX_DEPTH {
            return None;
        }
        self.skip_ws();
        match *self.bytes.get(self.at)? {
            b'{' => {
                self.at += 1;
                let mut fields = Vec::new();
                if self.eat(b'}').is_some() {
                    return Some(Json::Obj(fields));
                }
                loop {
                    self.skip_ws();
                    let key = self.string()?;
                    self.eat(b':')?;
                    fields.push((key, self.value(depth + 1)?));
                    if self.eat(b',').is_some() {
                        continue;
                    }
                    self.eat(b'}')?;
                    return Some(Json::Obj(fields));
                }
            }
            b'[' => {
                self.at += 1;
                let mut items = Vec::new();
                if self.eat(b']').is_some() {
                    return Some(Json::Arr(items));
                }
                loop {
                    items.push(self.value(depth + 1)?);
                    if self.eat(b',').is_some() {
                        continue;
                    }
                    self.eat(b']')?;
                    return Some(Json::Arr(items));
                }
            }
            b'"' => self.string().map(Json::Str),
            b't' => self.literal("true", Json::Bool(true)),
            b'f' => self.literal("false", Json::Bool(false)),
            b'n' => self.literal("null", Json::Null),
            b'-' | b'0'..=b'9' => self.number(),
            _ => None,
        }
    }

    fn number(&mut self) -> Option<Json> {
        let start = self.at;
        while matches!(
            self.bytes.get(self.at),
            Some(b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9')
        ) {
            self.at += 1;
        }
        let text = std::str::from_utf8(&self.bytes[start..self.at]).ok()?;
        let value: f64 = text.parse().ok()?;
        value.is_finite().then_some(Json::Num(value))
    }

    fn hex4(&mut self) -> Option<u32> {
        let end = self.at.checked_add(4)?;
        let digits = std::str::from_utf8(self.bytes.get(self.at..end)?).ok()?;
        let value = u32::from_str_radix(digits, 16).ok()?;
        self.at = end;
        Some(value)
    }

    fn string(&mut self) -> Option<String> {
        if self.bytes.get(self.at) != Some(&b'"') {
            return None;
        }
        self.at += 1;
        let mut out = Vec::new();
        loop {
            let byte = *self.bytes.get(self.at)?;
            self.at += 1;
            match byte {
                b'"' => return String::from_utf8(out).ok(),
                b'\\' => {
                    let escape = *self.bytes.get(self.at)?;
                    self.at += 1;
                    let ch = match escape {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => {
                            let high = self.hex4()?;
                            let code = if (0xD800..0xDC00).contains(&high) {
                                // A surrogate pair must follow as a second
                                // \u escape; a lone half is malformed.
                                if self.bytes.get(self.at..self.at + 2)? != b"\\u" {
                                    return None;
                                }
                                self.at += 2;
                                let low = self.hex4()?;
                                if !(0xDC00..0xE000).contains(&low) {
                                    return None;
                                }
                                0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                high
                            };
                            char::from_u32(code)?
                        }
                        _ => return None,
                    };
                    let mut buf = [0u8; 4];
                    out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                }
                // A raw control byte inside a string is not JSON.
                0x00..=0x1f => return None,
                _ => out.push(byte),
            }
        }
    }
}

/// `text` as a JSON string literal. Every control character is escaped,
/// so the result never carries a raw newline — it rides inside a
/// one-line protocol reply.
pub(crate) fn quote(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 || c == '\u{7f}' || c == '\u{2028}' || c == '\u{2029}' => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_shapes_the_compositor_answers_with() {
        let value = parse(r#"{"a": [1, -2.5, true, false, null], "b": {"c": "d"}}"#).unwrap();
        assert_eq!(value.get("a").unwrap().as_array().unwrap().len(), 5);
        assert_eq!(value.get("b").unwrap().get("c").unwrap().as_str(), Some("d"));
        assert_eq!(parse("  7 ").unwrap().as_u32(), Some(7));
        assert_eq!(parse("[]"), Some(Json::Arr(vec![])));
        assert_eq!(parse("{}"), Some(Json::Obj(vec![])));
    }

    #[test]
    fn decodes_every_escape_and_refuses_broken_ones() {
        assert_eq!(
            parse(r#""q\" b\\ s\/ n\n t\t ué p😀""#).unwrap().as_str(),
            Some("q\" b\\ s/ n\n t\t ué p😀")
        );
        // A lone surrogate half, an unknown escape, a raw control byte.
        assert!(parse(r#""\ud83d""#).is_none());
        assert!(parse(r#""\x""#).is_none());
        assert!(parse("\"a\nb\"").is_none());
    }

    #[test]
    fn malformed_documents_are_refused_whole() {
        for bad in [
            "", "{", "[1,", "{\"a\" 1}", "{\"a\":1,}", "[1 2]", "tru", "{} x", "\"open",
            "{1: 2}", "NaN", "1e999",
        ] {
            assert!(parse(bad).is_none(), "{bad:?} parsed");
        }
        // Nesting past the bound is refused, not recursed into.
        let deep = "[".repeat(64) + &"]".repeat(64);
        assert!(parse(&deep).is_none());
    }

    #[test]
    fn indices_are_whole_non_negative_numbers() {
        assert_eq!(Json::Num(2.0).as_u32(), Some(2));
        assert_eq!(Json::Num(-1.0).as_u32(), None);
        assert_eq!(Json::Num(1.5).as_u32(), None);
        assert_eq!(Json::Str("1".into()).as_u32(), None);
    }

    #[test]
    fn quoting_round_trips_and_never_breaks_the_line() {
        for text in ["plain", "q\"b\\s", "line\nbreak\ttab\u{1}\u{7f}", "влад", "\u{2028}"] {
            let quoted = quote(text);
            assert!(!quoted.contains('\n') && !quoted.contains('\r'));
            assert_eq!(parse(&quoted).unwrap().as_str(), Some(text));
        }
    }
}
