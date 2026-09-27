// den Shields: turns ABP-syntax filter lists into WebKit content-rule JSON with adblock-rust
// (MPL-2.0; a build-time tool only, nothing of it ships in den).
//   cbconv <out.json> [--no-generic-cosmetic] [--network-only] [--cosmetic-only] <list.txt>...
// Prints one stats line to stderr.
use adblock::content_blocking::{CbRule, CbType};
use adblock::lists::{FilterSet, ParseOptions};
use std::env;
use std::fs;

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let out = &args[0];
    let flag = |f: &str| args.iter().any(|a| a == f);
    let (no_generic, network_only, cosmetic_only) = (flag("--no-generic-cosmetic"), flag("--network-only"), flag("--cosmetic-only"));
    let lists: Vec<&String> = args[1..].iter().filter(|a| !a.starts_with("--")).collect();
    let mut set = FilterSet::new(true);
    let mut lines_in = 0usize;
    for l in &lists {
        let text = fs::read_to_string(l).expect("read list");
        lines_in += text.lines().count();
        set.add_filter_list(text.clone(), ParseOptions::default());
    }
    let (rules, used) = set.into_content_blocking().expect("content blocking");
    let mut kept: Vec<CbRule> = vec![];
    let (mut block, mut css, mut css_generic, mut ignore, mut other) = (0, 0, 0, 0, 0);
    for r in rules {
        let generic = r.trigger.if_domain.is_none() && r.trigger.unless_domain.is_none() && r.trigger.if_top_url.is_none();
        match r.action.typ {
            CbType::CssDisplayNone => {
                if network_only || (no_generic && generic) {
                    continue;
                }
                css += 1;
                if generic {
                    css_generic += 1;
                }
            }
            CbType::IgnorePreviousRules => {
                // Exceptions for cosmetic rules carry a selector-less trigger; keep all exceptions.
                ignore += 1
            }
            CbType::Block => {
                if cosmetic_only {
                    continue;
                }
                block += 1
            }
            _ => {
                if cosmetic_only {
                    continue;
                }
                other += 1
            }
        }
        kept.push(r);
    }
    fs::write(out, serde_json::to_string(&kept).unwrap()).unwrap();
    eprintln!(
        "{out}: lines={lines_in} used={} rules={} block={block} css={css} (generic {css_generic}) ignore={ignore} other={other}",
        used.len(),
        kept.len()
    );
}
