//! A deliberately small JSON-Schema validator, std + `serde_json` only (no `regex`, no
//! `jsonschema`: `stick/Cargo.lock` carries neither and the MSRV job pins the lock).
//!
//! It implements the subset of JSON Schema 2020-12 that `stick/schema/*.schema.json` uses
//! and nothing more. It is strict in the direction that matters: a keyword it does not
//! implement is an error when the schema is loaded ([`Schema::new`]), never a silently
//! skipped check, so extending a schema with `format`, `patternProperties`, ... fails the
//! tests until the validator learns the keyword (and its own tests).
//!
//! Supported keywords: `$schema $id $comment title description default examples` (ignored
//! annotations), `$defs`, `$ref` (local `#/...` pointers), `type` (string or array),
//! `enum`, `const`, `required`, `properties`, `additionalProperties` (bool or schema),
//! `items`, `minItems`, `maxItems`, `uniqueItems`, `minLength`, `maxLength`, `minimum`,
//! `maximum`, `pattern`, `not`, `if`/`then`/`else`, `allOf`, `anyOf`, `oneOf`, plus boolean
//! schemas.
//!
//! `pattern` is evaluated by [`Regex`], a small backtracking engine for the ECMA-262
//! subset the schemas use: literals, `.`, classes (`[a-z]`, `[^...]`, `\d \w \s`, `\uXXXX`),
//! `^ $`, groups `( ) (?: )`, alternation, greedy `* + ? {n} {n,} {n,m}`, and lookahead
//! `(?= ) (?! )`. Back-references, lazy quantifiers, look-behind and flags are rejected when
//! the pattern is compiled.
//!
//! This file is shared by `tests/schema.rs` through `#[path]`. Its own tests run there.

#![allow(dead_code)]

use std::cmp::Ordering;
use std::collections::BTreeMap;

use serde_json::Value;

// ---------------------------------------------------------------------------------------
// Regular expressions
// ---------------------------------------------------------------------------------------

#[derive(Debug, Clone)]
enum ClassItem {
    Range(char, char),
    Digit(bool),
    Word(bool),
    Space(bool),
}

#[derive(Debug, Clone)]
struct Class {
    negate: bool,
    items: Vec<ClassItem>,
}

impl Class {
    fn matches(&self, c: char) -> bool {
        let hit = self.items.iter().any(|i| match *i {
            ClassItem::Range(lo, hi) => lo <= c && c <= hi,
            ClassItem::Digit(neg) => c.is_ascii_digit() != neg,
            ClassItem::Word(neg) => (c.is_ascii_alphanumeric() || c == '_') != neg,
            ClassItem::Space(neg) => is_js_space(c) != neg,
        });
        hit != self.negate
    }
}

fn is_js_space(c: char) -> bool {
    matches!(
        c,
        ' ' | '\t'
            | '\n'
            | '\r'
            | '\u{b}'
            | '\u{c}'
            | '\u{a0}'
            | '\u{feff}'
            | '\u{2028}'
            | '\u{2029}'
    ) || (c.is_whitespace() && !c.is_ascii())
}

#[derive(Debug, Clone)]
enum Node {
    Char(char),
    Any,
    Class(Class),
    Start,
    End,
    Seq(Vec<Node>),
    Alt(Vec<Node>),
    Repeat {
        node: Box<Node>,
        min: usize,
        max: Option<usize>,
    },
    Look {
        node: Box<Node>,
        negate: bool,
    },
}

/// A compiled pattern. `is_match` searches (JSON Schema `pattern` is not implicitly
/// anchored), so schemas anchor with `^` and `$` themselves.
#[derive(Debug, Clone)]
pub struct Regex {
    root: Node,
}

struct Parser {
    chars: Vec<char>,
    pos: usize,
}

impl Parser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn eat(&mut self, c: char) -> bool {
        if self.peek() == Some(c) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn starts_with(&self, s: &str) -> bool {
        s.chars()
            .enumerate()
            .all(|(i, c)| self.chars.get(self.pos + i) == Some(&c))
    }

    fn alt(&mut self) -> Result<Node, String> {
        let mut branches = vec![self.seq()?];
        while self.eat('|') {
            branches.push(self.seq()?);
        }
        Ok(if branches.len() == 1 {
            branches.remove(0)
        } else {
            Node::Alt(branches)
        })
    }

    fn seq(&mut self) -> Result<Node, String> {
        let mut items = Vec::new();
        while let Some(c) = self.peek() {
            if c == '|' || c == ')' {
                break;
            }
            let atom = self.atom()?;
            items.push(self.quantified(atom)?);
        }
        Ok(Node::Seq(items))
    }

    fn quantified(&mut self, atom: Node) -> Result<Node, String> {
        let (min, max) = match self.peek() {
            Some('*') => (0, None),
            Some('+') => (1, None),
            Some('?') => (0, Some(1)),
            Some('{') => {
                self.pos += 1;
                let (min, max) = self.braces()?;
                if matches!(self.peek(), Some('?' | '+')) {
                    return Err("lazy or possessive quantifiers are not supported".into());
                }
                return Ok(Node::Repeat {
                    node: Box::new(atom),
                    min,
                    max,
                });
            }
            _ => return Ok(atom),
        };
        self.pos += 1;
        if matches!(self.peek(), Some('?' | '+')) {
            return Err("lazy or possessive quantifiers are not supported".into());
        }
        Ok(Node::Repeat {
            node: Box::new(atom),
            min,
            max,
        })
    }

    /// After `{`: `n}`, `n,}` or `n,m}`.
    fn braces(&mut self) -> Result<(usize, Option<usize>), String> {
        let min = self.number()?;
        let max = if self.eat(',') {
            if self.peek() == Some('}') {
                None
            } else {
                Some(self.number()?)
            }
        } else {
            Some(min)
        };
        if !self.eat('}') {
            return Err("unterminated {n,m} quantifier".into());
        }
        if matches!(max, Some(m) if m < min) {
            return Err("quantifier {n,m} with m < n".into());
        }
        Ok((min, max))
    }

    fn number(&mut self) -> Result<usize, String> {
        let start = self.pos;
        while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
            self.pos += 1;
        }
        if start == self.pos {
            return Err("expected a number in a {n,m} quantifier".into());
        }
        self.chars[start..self.pos]
            .iter()
            .collect::<String>()
            .parse()
            .map_err(|_| "quantifier number out of range".to_string())
    }

    fn atom(&mut self) -> Result<Node, String> {
        let c = self.peek().ok_or("unexpected end of pattern")?;
        self.pos += 1;
        match c {
            '(' => {
                let node = if self.starts_with("?:") {
                    self.pos += 2;
                    self.alt()?
                } else if self.starts_with("?!") || self.starts_with("?=") {
                    let negate = self.chars[self.pos + 1] == '!';
                    self.pos += 2;
                    Node::Look {
                        node: Box::new(self.alt()?),
                        negate,
                    }
                } else if self.peek() == Some('?') {
                    return Err("unsupported group construct (only (?: ), (?= ), (?! ))".into());
                } else {
                    self.alt()?
                };
                if !self.eat(')') {
                    return Err("unterminated group".into());
                }
                Ok(node)
            }
            '[' => self.class(),
            '.' => Ok(Node::Any),
            '^' => Ok(Node::Start),
            '$' => Ok(Node::End),
            '\\' => Ok(match self.escape()? {
                Esc::Char(c) => Node::Char(c),
                Esc::Class(item) => Node::Class(Class {
                    negate: false,
                    items: vec![item],
                }),
            }),
            '*' | '+' | '?' | '{' => Err(format!("nothing to repeat before {c:?}")),
            c => Ok(Node::Char(c)),
        }
    }

    /// After a backslash.
    fn escape(&mut self) -> Result<Esc, String> {
        let c = self.peek().ok_or("pattern ends with a backslash")?;
        self.pos += 1;
        Ok(match c {
            'd' => Esc::Class(ClassItem::Digit(false)),
            'D' => Esc::Class(ClassItem::Digit(true)),
            'w' => Esc::Class(ClassItem::Word(false)),
            'W' => Esc::Class(ClassItem::Word(true)),
            's' => Esc::Class(ClassItem::Space(false)),
            'S' => Esc::Class(ClassItem::Space(true)),
            'n' => Esc::Char('\n'),
            'r' => Esc::Char('\r'),
            't' => Esc::Char('\t'),
            'f' => Esc::Char('\u{c}'),
            'v' => Esc::Char('\u{b}'),
            '0' => Esc::Char('\0'),
            'u' => {
                let mut v = 0u32;
                for _ in 0..4 {
                    let d = self
                        .peek()
                        .and_then(|h| h.to_digit(16))
                        .ok_or("\\u needs four hex digits")?;
                    self.pos += 1;
                    v = v * 16 + d;
                }
                Esc::Char(char::from_u32(v).ok_or("\\u escape is not a scalar value")?)
            }
            c if c.is_ascii_alphanumeric() => {
                return Err(format!("unsupported escape \\{c}"));
            }
            c => Esc::Char(c),
        })
    }

    /// After `[`.
    fn class(&mut self) -> Result<Node, String> {
        let negate = self.eat('^');
        let mut items = Vec::new();
        loop {
            let c = self.peek().ok_or("unterminated character class")?;
            self.pos += 1;
            if c == ']' {
                break;
            }
            let lo = match c {
                '\\' => match self.escape()? {
                    Esc::Char(c) => c,
                    Esc::Class(item) => {
                        items.push(item);
                        continue;
                    }
                },
                c => c,
            };
            // `a-z`, but a trailing '-' ("[a-]") is a literal dash.
            if self.peek() == Some('-') && self.chars.get(self.pos + 1).is_some_and(|&n| n != ']') {
                self.pos += 1;
                let hi = match self.peek().ok_or("unterminated character class")? {
                    '\\' => {
                        self.pos += 1;
                        match self.escape()? {
                            Esc::Char(c) => c,
                            Esc::Class(_) => return Err("a class escape cannot end a range".into()),
                        }
                    }
                    c => {
                        self.pos += 1;
                        c
                    }
                };
                if hi < lo {
                    return Err(format!("character range {lo:?}-{hi:?} is reversed"));
                }
                items.push(ClassItem::Range(lo, hi));
            } else {
                items.push(ClassItem::Range(lo, lo));
            }
        }
        if items.is_empty() {
            return Err("empty character class".into());
        }
        Ok(Node::Class(Class { negate, items }))
    }
}

enum Esc {
    Char(char),
    Class(ClassItem),
}

struct Matcher<'a> {
    text: &'a [char],
}

impl Matcher<'_> {
    fn m(&self, node: &Node, pos: usize, k: &mut dyn FnMut(usize) -> bool) -> bool {
        match node {
            Node::Char(c) => self.text.get(pos) == Some(c) && k(pos + 1),
            Node::Any => {
                matches!(self.text.get(pos), Some(&c) if !matches!(c, '\n' | '\r' | '\u{2028}' | '\u{2029}'))
                    && k(pos + 1)
            }
            Node::Class(class) => {
                matches!(self.text.get(pos), Some(&c) if class.matches(c)) && k(pos + 1)
            }
            Node::Start => pos == 0 && k(pos),
            Node::End => pos == self.text.len() && k(pos),
            Node::Seq(nodes) => self.seq(nodes, pos, k),
            Node::Alt(branches) => {
                for b in branches {
                    if self.m(b, pos, &mut *k) {
                        return true;
                    }
                }
                false
            }
            Node::Repeat { node, min, max } => self.rep(node, *min, *max, 0, pos, k),
            Node::Look { node, negate } => {
                let found = self.m(node, pos, &mut |_| true);
                found != *negate && k(pos)
            }
        }
    }

    fn seq(&self, nodes: &[Node], pos: usize, k: &mut dyn FnMut(usize) -> bool) -> bool {
        match nodes.split_first() {
            None => k(pos),
            Some((first, rest)) => self.m(first, pos, &mut |p| self.seq(rest, p, &mut *k)),
        }
    }

    fn rep(
        &self,
        node: &Node,
        min: usize,
        max: Option<usize>,
        count: usize,
        pos: usize,
        k: &mut dyn FnMut(usize) -> bool,
    ) -> bool {
        if max.map_or(true, |mx| count < mx) {
            let took = self.m(node, pos, &mut |p| {
                // An iteration that consumed nothing cannot help once `min` is met.
                if p == pos && count >= min {
                    false
                } else {
                    self.rep(node, min, max, count + 1, p, &mut *k)
                }
            });
            if took {
                return true;
            }
        }
        count >= min && k(pos)
    }
}

impl Regex {
    pub fn new(pattern: &str) -> Result<Self, String> {
        let mut p = Parser {
            chars: pattern.chars().collect(),
            pos: 0,
        };
        let root = p.alt()?;
        if p.pos != p.chars.len() {
            return Err(format!("unbalanced ')' at offset {}", p.pos));
        }
        Ok(Regex { root })
    }

    pub fn is_match(&self, text: &str) -> bool {
        let chars: Vec<char> = text.chars().collect();
        let matcher = Matcher { text: &chars };
        (0..=chars.len()).any(|start| matcher.m(&self.root, start, &mut |_| true))
    }
}

// ---------------------------------------------------------------------------------------
// The schema validator
// ---------------------------------------------------------------------------------------

pub struct Schema {
    root: Value,
    patterns: BTreeMap<String, Regex>,
}

const MAX_DEPTH: usize = 64;
const TYPES: [&str; 7] = [
    "null", "boolean", "object", "array", "string", "number", "integer",
];

impl Schema {
    /// Load a schema. Fails if it uses a keyword this validator does not implement, has a
    /// `$ref` that does not resolve, or has a `pattern` outside the supported subset.
    pub fn new(root: Value) -> Result<Schema, String> {
        let mut schema = Schema {
            root: root.clone(),
            patterns: BTreeMap::new(),
        };
        let mut errors = Vec::new();
        schema.walk(&root, "#", &mut errors);
        if errors.is_empty() {
            Ok(schema)
        } else {
            Err(errors.join("\n"))
        }
    }

    pub fn parse(text: &str) -> Result<Schema, String> {
        Schema::new(serde_json::from_str(text).map_err(|e| format!("schema is not JSON: {e}"))?)
    }

    /// Validate against the whole schema. Empty = valid. Messages are `<json-pointer>: <why>`.
    pub fn validate(&self, instance: &Value) -> Vec<String> {
        let mut errors = Vec::new();
        self.check(&self.root, instance, "", 0, &mut errors);
        errors
    }

    /// Validate against `#/$defs/<name>` (for example `model_pack` for one catalog pack).
    pub fn validate_def(&self, name: &str, instance: &Value) -> Vec<String> {
        let mut errors = Vec::new();
        match self.root.pointer(&format!("/$defs/{name}")) {
            Some(def) => self.check(def, instance, "", 0, &mut errors),
            None => errors.push(format!("schema has no $defs/{name}")),
        }
        errors
    }

    fn walk(&mut self, node: &Value, at: &str, errors: &mut Vec<String>) {
        let obj = match node {
            Value::Bool(_) => return,
            Value::Object(o) => o,
            _ => {
                errors.push(format!("{at}: a schema must be an object or a boolean"));
                return;
            }
        };
        for (key, val) in obj {
            let here = format!("{at}/{key}");
            match key.as_str() {
                "$schema" | "$id" | "$comment" | "title" | "description" | "default"
                | "examples" | "const" => {}
                "$defs" | "properties" => match val.as_object() {
                    Some(map) => {
                        for (name, sub) in map {
                            self.walk(sub, &format!("{here}/{name}"), errors);
                        }
                    }
                    None => errors.push(format!("{here}: must be an object of schemas")),
                },
                "$ref" => match val.as_str() {
                    Some(r) if r.starts_with('#') && self.resolve(r).is_some() => {}
                    Some(r) => errors.push(format!("{here}: $ref {r:?} does not resolve locally")),
                    None => errors.push(format!("{here}: $ref must be a string")),
                },
                "type" => {
                    let names: Vec<&Value> = match val {
                        Value::Array(a) => a.iter().collect(),
                        v => vec![v],
                    };
                    for n in names {
                        if !n.as_str().is_some_and(|s| TYPES.contains(&s)) {
                            errors.push(format!("{here}: unknown type {n}"));
                        }
                    }
                }
                "enum" => {
                    if !val.as_array().is_some_and(|a| !a.is_empty()) {
                        errors.push(format!("{here}: enum must be a non-empty array"));
                    }
                }
                "required" => {
                    let ok = val
                        .as_array()
                        .is_some_and(|a| a.iter().all(|s| s.is_string()));
                    if !ok {
                        errors.push(format!("{here}: required must be an array of strings"));
                    }
                }
                "additionalProperties" | "items" | "not" | "if" | "then" | "else" => {
                    if val.is_array() {
                        errors.push(format!("{here}: an array form is not supported"));
                    } else {
                        self.walk(val, &here, errors);
                    }
                }
                "allOf" | "anyOf" | "oneOf" => match val.as_array() {
                    Some(a) if !a.is_empty() => {
                        for (i, sub) in a.iter().enumerate() {
                            self.walk(sub, &format!("{here}/{i}"), errors);
                        }
                    }
                    _ => errors.push(format!("{here}: must be a non-empty array of schemas")),
                },
                "minItems" | "maxItems" | "minLength" | "maxLength" => {
                    if val.as_u64().is_none() {
                        errors.push(format!("{here}: must be a non-negative integer"));
                    }
                }
                "minimum" | "maximum" => {
                    if !val.is_number() {
                        errors.push(format!("{here}: must be a number"));
                    }
                }
                "uniqueItems" => {
                    if !val.is_boolean() {
                        errors.push(format!("{here}: must be a boolean"));
                    }
                }
                "pattern" => match val.as_str().map(|p| (p, Regex::new(p))) {
                    Some((p, Ok(re))) => {
                        self.patterns.insert(p.to_string(), re);
                    }
                    Some((p, Err(e))) => {
                        errors.push(format!("{here}: pattern {p:?} is unsupported: {e}"));
                    }
                    None => errors.push(format!("{here}: pattern must be a string")),
                },
                other => errors.push(format!(
                    "{here}: keyword {other:?} is not implemented by minischema (extend it, with a test, before using it)"
                )),
            }
        }
    }

    fn resolve(&self, reference: &str) -> Option<&Value> {
        let pointer = reference.strip_prefix('#')?;
        if pointer.is_empty() {
            Some(&self.root)
        } else {
            self.root.pointer(pointer)
        }
    }

    fn check(
        &self,
        schema: &Value,
        inst: &Value,
        at: &str,
        depth: usize,
        errors: &mut Vec<String>,
    ) {
        let place = if at.is_empty() { "/" } else { at };
        if depth > MAX_DEPTH {
            errors.push(format!("{place}: schema nesting/$ref cycle is too deep"));
            return;
        }
        let obj = match schema {
            Value::Bool(true) => return,
            Value::Bool(false) => {
                errors.push(format!("{place}: not allowed here"));
                return;
            }
            Value::Object(o) => o,
            _ => return, // rejected at load
        };

        if let Some(r) = obj.get("$ref").and_then(Value::as_str) {
            match self.resolve(r) {
                Some(target) => self.check(target, inst, at, depth + 1, errors),
                None => errors.push(format!("{place}: unresolved $ref {r}")),
            }
        }

        if let Some(t) = obj.get("type") {
            let allowed: Vec<&str> = match t {
                Value::Array(a) => a.iter().filter_map(Value::as_str).collect(),
                v => v.as_str().into_iter().collect(),
            };
            if !allowed.iter().any(|name| type_matches(name, inst)) {
                errors.push(format!(
                    "{place}: expected type {} but found {}",
                    allowed.join("|"),
                    type_name(inst)
                ));
            }
        }
        if let Some(c) = obj.get("const") {
            if c != inst {
                errors.push(format!("{place}: must equal {c} (found {})", short(inst)));
            }
        }
        if let Some(Value::Array(options)) = obj.get("enum") {
            if !options.contains(inst) {
                errors.push(format!(
                    "{place}: {} is not one of {}",
                    short(inst),
                    Value::Array(options.clone())
                ));
            }
        }

        match inst {
            Value::Object(map) => {
                if let Some(Value::Array(req)) = obj.get("required") {
                    for name in req.iter().filter_map(Value::as_str) {
                        if !map.contains_key(name) {
                            errors.push(format!("{place}: missing required property {name:?}"));
                        }
                    }
                }
                let props = obj.get("properties").and_then(Value::as_object);
                for (name, value) in map {
                    let child = format!("{at}/{}", pointer_escape(name));
                    match props.and_then(|p| p.get(name)) {
                        Some(sub) => self.check(sub, value, &child, depth + 1, errors),
                        None => match obj.get("additionalProperties") {
                            Some(Value::Bool(false)) => {
                                errors.push(format!("{child}: unknown property {name:?}"));
                            }
                            Some(sub @ Value::Object(_)) => {
                                self.check(sub, value, &child, depth + 1, errors);
                            }
                            _ => {}
                        },
                    }
                }
            }
            Value::Array(items) => {
                if let Some(n) = obj.get("minItems").and_then(Value::as_u64) {
                    if (items.len() as u64) < n {
                        errors.push(format!(
                            "{place}: needs at least {n} items, has {}",
                            items.len()
                        ));
                    }
                }
                if let Some(n) = obj.get("maxItems").and_then(Value::as_u64) {
                    if (items.len() as u64) > n {
                        errors.push(format!(
                            "{place}: allows at most {n} items, has {}",
                            items.len()
                        ));
                    }
                }
                if obj.get("uniqueItems") == Some(&Value::Bool(true)) {
                    for (i, a) in items.iter().enumerate() {
                        if items[..i].contains(a) {
                            errors.push(format!("{place}: item {i} duplicates an earlier item"));
                        }
                    }
                }
                if let Some(sub) = obj.get("items") {
                    for (i, item) in items.iter().enumerate() {
                        self.check(sub, item, &format!("{at}/{i}"), depth + 1, errors);
                    }
                }
            }
            Value::String(s) => {
                let len = s.chars().count() as u64;
                if let Some(n) = obj.get("minLength").and_then(Value::as_u64) {
                    if len < n {
                        errors.push(format!("{place}: shorter than {n} characters"));
                    }
                }
                if let Some(n) = obj.get("maxLength").and_then(Value::as_u64) {
                    if len > n {
                        errors.push(format!("{place}: longer than {n} characters"));
                    }
                }
                if let Some(p) = obj.get("pattern").and_then(Value::as_str) {
                    let ok = self.patterns.get(p).is_some_and(|re| re.is_match(s));
                    if !ok {
                        errors.push(format!(
                            "{place}: {} does not match pattern {p}",
                            short(inst)
                        ));
                    }
                }
            }
            Value::Number(_) => {
                if let Some(bound) = obj.get("minimum") {
                    if num_cmp(inst, bound) == Some(Ordering::Less) {
                        errors.push(format!("{place}: {inst} is below the minimum {bound}"));
                    }
                }
                if let Some(bound) = obj.get("maximum") {
                    if num_cmp(inst, bound) == Some(Ordering::Greater) {
                        errors.push(format!("{place}: {inst} is above the maximum {bound}"));
                    }
                }
            }
            _ => {}
        }

        if let Some(sub) = obj.get("not") {
            if self.valid(sub, inst, depth) {
                errors.push(format!(
                    "{place}: {} matches a schema it must not match",
                    short(inst)
                ));
            }
        }
        if let Some(Value::Array(subs)) = obj.get("allOf") {
            for sub in subs {
                self.check(sub, inst, at, depth + 1, errors);
            }
        }
        if let Some(Value::Array(subs)) = obj.get("anyOf") {
            if !subs.iter().any(|s| self.valid(s, inst, depth)) {
                errors.push(format!("{place}: matches none of the anyOf alternatives"));
            }
        }
        if let Some(Value::Array(subs)) = obj.get("oneOf") {
            let n = subs.iter().filter(|s| self.valid(s, inst, depth)).count();
            if n != 1 {
                errors.push(format!(
                    "{place}: matches {n} of the oneOf alternatives, needs exactly 1"
                ));
            }
        }
        if let Some(cond) = obj.get("if") {
            if self.valid(cond, inst, depth) {
                if let Some(then) = obj.get("then") {
                    self.check(then, inst, at, depth + 1, errors);
                }
            } else if let Some(otherwise) = obj.get("else") {
                self.check(otherwise, inst, at, depth + 1, errors);
            }
        }
    }

    fn valid(&self, schema: &Value, inst: &Value, depth: usize) -> bool {
        let mut errors = Vec::new();
        self.check(schema, inst, "", depth + 1, &mut errors);
        errors.is_empty()
    }
}

fn pointer_escape(name: &str) -> String {
    name.replace('~', "~0").replace('/', "~1")
}

fn type_name(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) if is_integer(v) => "integer",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn type_matches(name: &str, v: &Value) -> bool {
    match name {
        "null" => v.is_null(),
        "boolean" => v.is_boolean(),
        "object" => v.is_object(),
        "array" => v.is_array(),
        "string" => v.is_string(),
        "number" => v.is_number(),
        "integer" => is_integer(v),
        _ => false,
    }
}

fn is_integer(v: &Value) -> bool {
    match v {
        Value::Number(n) => {
            n.is_i64()
                || n.is_u64()
                || n.as_f64()
                    .is_some_and(|f| f.is_finite() && f.fract() == 0.0)
        }
        _ => false,
    }
}

/// Exact for integers (i128), f64 otherwise.
fn num_cmp(a: &Value, b: &Value) -> Option<Ordering> {
    let (Value::Number(x), Value::Number(y)) = (a, b) else {
        return None;
    };
    let as_i128 = |n: &serde_json::Number| {
        n.as_i64()
            .map(i128::from)
            .or_else(|| n.as_u64().map(i128::from))
    };
    match (as_i128(x), as_i128(y)) {
        (Some(p), Some(q)) => Some(p.cmp(&q)),
        _ => x.as_f64()?.partial_cmp(&y.as_f64()?),
    }
}

/// Truncated JSON for messages.
fn short(v: &Value) -> String {
    let s = v.to_string();
    if s.chars().count() > 80 {
        format!("{}...", s.chars().take(77).collect::<String>())
    } else {
        s
    }
}

// ---------------------------------------------------------------------------------------
// Self-tests (run as part of tests/schema.rs)
// ---------------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn re(p: &str) -> Regex {
        Regex::new(p).unwrap_or_else(|e| panic!("{p}: {e}"))
    }

    #[test]
    fn regex_literals_anchors_and_classes() {
        let digest = re("^sha256:[0-9a-f]{64}$");
        assert!(digest.is_match(&format!("sha256:{}", "a".repeat(64))));
        assert!(!digest.is_match(&format!("sha256:{}", "A".repeat(64))));
        assert!(!digest.is_match(&format!("sha256:{}", "a".repeat(63))));
        assert!(!digest.is_match(&format!("sha256:{}0", "a".repeat(64))));
        assert!(!digest.is_match(&format!("md5:{}", "a".repeat(64))));

        let ident = re("^[a-z0-9][a-z0-9._-]*$");
        for ok in ["a", "0", "stick-128", "qwen3.5", "a_b", "x.y-z"] {
            assert!(ident.is_match(ok), "{ok}");
        }
        for bad in ["", "-a", ".a", "A", "a b", "a/b", "a\n"] {
            assert!(!ident.is_match(bad), "{bad:?}");
        }

        // Unanchored patterns search; anchors do not.
        assert!(re("b+").is_match("aabbbcc"));
        assert!(!re("^b+").is_match("aabbbcc"));
        assert!(re("c$").is_match("abc"));
        assert!(!re("^$").is_match("x"));
        assert!(re("^$").is_match(""));
    }

    #[test]
    fn regex_groups_alternation_quantifiers_and_lookahead() {
        let r = re("^(foo|bar)+(baz)?$");
        assert!(r.is_match("foobar"));
        assert!(r.is_match("barfoobaz"));
        assert!(!r.is_match("baz"));
        assert!(re("^a{2,3}$").is_match("aa"));
        assert!(re("^a{2,3}$").is_match("aaa"));
        assert!(!re("^a{2,3}$").is_match("a"));
        assert!(!re("^a{2,3}$").is_match("aaaa"));
        assert!(re("^a{2,}$").is_match("aaaaaa"));
        assert!(re("^(?:ab)*$").is_match("ababab"));
        assert!(!re("^(?:ab)*$").is_match("aba"));
        // Backtracking: greedy `.*` must give characters back.
        assert!(re("^.*c$").is_match("abcabc"));
        assert!(re("^(a*)*b$").is_match("aaab"));
        assert!(!re("^(a*)*b$").is_match("aaac"));
        // Lookahead.
        assert!(re("^(?!x)[a-z]+$").is_match("abc"));
        assert!(!re("^(?!x)[a-z]+$").is_match("xbc"));
        assert!(re("^(?=a)[a-z]+$").is_match("abc"));
        assert!(!re("^(?=a)[a-z]+$").is_match("bbc"));
    }

    #[test]
    fn regex_escapes_and_negated_classes() {
        assert!(re(r"^\d{4}-\d{2}$").is_match("2026-10"));
        assert!(!re(r"^\d{4}-\d{2}$").is_match("2026-1x"));
        assert!(re(r"^\w+\s\S+$").is_match("ab cd"));
        assert!(re(r"^a\.b$").is_match("a.b"));
        assert!(!re(r"^a\.b$").is_match("axb"));
        let no_ctl = re(r"^[^\\:\u0000-\u001f\u007f]+$");
        assert!(no_ctl.is_match("models/blobs/sha256-ab"));
        for bad in ["a\\b", "a:b", "a\u{0}b", "a\nb", "a\u{7f}b", ""] {
            assert!(!no_ctl.is_match(bad), "{bad:?}");
        }
        assert!(re(r"^[a\-z]+$").is_match("a-z"));
        assert!(re(r"^[a-]+$").is_match("a-a"));
        assert!(
            re("^.$").is_match("é"),
            "'.' matches one scalar value, not one byte"
        );
        assert!(!re("^.$").is_match("\n"));
    }

    #[test]
    fn regex_rejects_what_it_does_not_implement() {
        for bad in [
            "(", "(a", "a)", "[a", "[]", "[b-a]", "a{2", "a{3,2}", "*a", "+", "a**", "a*?", "a+?",
            r"\q", r"(\1)", "(?<=a)b", "(?<n>a)", "a\\", r"\u12",
        ] {
            assert!(Regex::new(bad).is_err(), "{bad:?} should not compile");
        }
    }

    #[test]
    fn rel_path_pattern_from_the_bundle_schema_behaves() {
        // The same expression bundle.schema.json uses for artifact paths.
        let p = re(r"^(?!/)(?!.*(^|/)\.{1,2}(/|$))(?!.*//)(?!.*/$)[^\\:\u0000-\u001f\u007f]+$");
        for ok in [
            "a",
            "boot/x.img",
            "models/blobs/sha256-0123",
            "a.b/.hidden",
            "a/..b",
            "a/b..",
        ] {
            assert!(p.is_match(ok), "{ok}");
        }
        for bad in [
            "", "/a", "a//b", "a/", "../a", "a/..", "a/../b", ".", "./a", "a/./b", "a\\b", "a:b",
        ] {
            assert!(!p.is_match(bad), "{bad:?}");
        }
    }

    fn schema(v: Value) -> Schema {
        Schema::new(v).expect("schema loads")
    }

    #[test]
    fn validates_types_required_and_additional_properties() {
        let s = schema(json!({
            "type": "object",
            "additionalProperties": false,
            "required": ["a"],
            "properties": {
                "a": {"type": "integer", "minimum": 1, "maximum": 10},
                "b": {"type": ["string", "null"], "pattern": "^x"},
                "c": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 2, "uniqueItems": true}
            }
        }));
        assert!(s
            .validate(&json!({"a": 1, "b": null, "c": ["p", "q"]}))
            .is_empty());
        assert!(
            s.validate(&json!({"a": 10.0})).is_empty(),
            "1.0-style integers are integers"
        );
        let all = |v: Value| s.validate(&v).join("\n");
        assert!(all(json!({})).contains("missing required property \"a\""));
        assert!(all(json!({"a": "1"})).contains("/a: expected type integer but found string"));
        assert!(all(json!({"a": 1.5})).contains("expected type integer but found number"));
        assert!(all(json!({"a": 0})).contains("below the minimum"));
        assert!(all(json!({"a": 11})).contains("above the maximum"));
        assert!(all(json!({"a": 1, "z": 1})).contains("unknown property \"z\""));
        assert!(all(json!({"a": 1, "b": "y"})).contains("/b: \"y\" does not match pattern"));
        assert!(all(json!({"a": 1, "b": 5})).contains("/b: expected type string|null"));
        assert!(all(json!({"a": 1, "c": []})).contains("at least 1 items"));
        assert!(all(json!({"a": 1, "c": ["p", "q", "r"]})).contains("at most 2 items"));
        assert!(all(json!({"a": 1, "c": ["p", "p"]})).contains("duplicates"));
        assert!(all(json!({"a": 1, "c": [1]})).contains("/c/0: expected type string"));
        assert!(all(json!([1])).contains("expected type object but found array"));
    }

    #[test]
    fn exact_integer_bounds_beyond_f64_precision() {
        let s = schema(json!({"type": "integer", "minimum": 9007199254740993u64}));
        assert!(s.validate(&json!(9007199254740993u64)).is_empty());
        assert!(!s.validate(&json!(9007199254740992u64)).is_empty());
        let s = schema(json!({"type": "integer", "minimum": 1}));
        assert!(!s.validate(&json!(-1)).is_empty());
        assert!(s.validate(&json!(u64::MAX)).is_empty());
    }

    #[test]
    fn validates_enum_const_not_and_conditionals() {
        let s = schema(json!({
            "type": "object",
            "properties": {
                "kind": {"enum": ["a", "b"]},
                "v": {"const": 1},
                "name": {"not": {"enum": ["reserved"]}}
            },
            "if": {"properties": {"kind": {"const": "a"}}, "required": ["kind"]},
            "then": {"required": ["x"]},
            "else": {"not": {"required": ["x"]}}
        }));
        assert!(s.validate(&json!({"kind": "a", "x": 1, "v": 1})).is_empty());
        assert!(s.validate(&json!({"kind": "b"})).is_empty());
        let all = |v: Value| s.validate(&v).join("\n");
        assert!(all(json!({"kind": "c"})).contains("is not one of"));
        assert!(all(json!({"v": 2})).contains("must equal 1"));
        assert!(all(json!({"name": "reserved"})).contains("must not match"));
        assert!(
            all(json!({"kind": "a"})).contains("missing required property \"x\""),
            "then branch"
        );
        assert!(
            all(json!({"kind": "b", "x": 1})).contains("must not match"),
            "else branch"
        );
    }

    #[test]
    fn validates_composition_and_refs() {
        let s = schema(json!({
            "$defs": {"small": {"type": "integer", "maximum": 5}, "big": {"type": "integer", "minimum": 100}},
            "anyOf": [{"$ref": "#/$defs/small"}, {"$ref": "#/$defs/big"}]
        }));
        assert!(s.validate(&json!(3)).is_empty());
        assert!(s.validate(&json!(500)).is_empty());
        assert!(s.validate(&json!(50)).join("").contains("anyOf"));
        assert!(s
            .validate_def("small", &json!(9))
            .join("")
            .contains("above the maximum"));
        assert!(s
            .validate_def("nope", &json!(1))
            .join("")
            .contains("no $defs/nope"));
        let one = schema(json!({"oneOf": [{"type": "integer"}, {"minimum": 0}]}));
        assert!(one
            .validate(&json!(3))
            .join("")
            .contains("matches 2 of the oneOf"));
        assert!(one.validate(&json!(-3)).is_empty());
        let all = schema(json!({"allOf": [{"minimum": 1}, {"maximum": 3}]}));
        assert!(all.validate(&json!(2)).is_empty());
        assert!(!all.validate(&json!(4)).is_empty());
    }

    #[test]
    fn a_ref_cycle_is_an_error_not_a_hang() {
        let s = schema(json!({"$defs": {"a": {"$ref": "#/$defs/a"}}, "$ref": "#/$defs/a"}));
        assert!(s.validate(&json!(1)).join("").contains("too deep"));
    }

    #[test]
    fn unsupported_schemas_are_rejected_when_loaded() {
        let bad = |v: Value| Schema::new(v).err().unwrap_or_default();
        assert!(bad(json!({"format": "uri"})).contains("keyword \"format\""));
        assert!(bad(json!({"patternProperties": {}})).contains("patternProperties"));
        assert!(bad(json!({"properties": {"a": {"minContains": 1}}}))
            .contains("/properties/a/minContains"));
        assert!(bad(json!({"$ref": "#/$defs/missing"})).contains("does not resolve"));
        assert!(
            bad(json!({"$ref": "http://example.com/x.json"})).contains("does not resolve locally")
        );
        assert!(bad(json!({"pattern": "(?<=a)b"})).contains("unsupported"));
        assert!(bad(json!({"type": "float"})).contains("unknown type"));
        assert!(bad(json!({"enum": []})).contains("non-empty"));
        assert!(bad(json!({"minItems": -1})).contains("non-negative"));
        assert!(bad(json!({"items": [{"type": "string"}]})).contains("array form"));
        assert!(bad(json!(5)).contains("must be an object or a boolean"));
    }

    #[test]
    fn boolean_schemas_work() {
        let s = schema(json!({"properties": {"a": true, "b": false}}));
        assert!(s.validate(&json!({"a": 1})).is_empty());
        assert!(s
            .validate(&json!({"b": 1}))
            .join("")
            .contains("not allowed here"));
    }
}
