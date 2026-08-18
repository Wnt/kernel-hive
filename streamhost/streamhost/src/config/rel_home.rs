//! SH_REL_HOME_ON — the relative-pointer bridge's re-home trigger list. Lives
//! in `config` (std-only) so the lib build sees it; the machinery is in
//! `rel_bridge.rs`.

/// Which events re-home the bridge (SH_REL_HOME_ON=session,reset,resume,focus,
/// idle,edge). `session` is always on — a fresh session has an unknown guest
/// cursor and today's seed IS that trigger.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RelHomeOn {
    pub reset: bool,
    pub resume: bool,
    pub focus: bool,
    pub idle: bool,
    pub edge: bool,
}

impl RelHomeOn {
    /// Parse the comma list. Unknown words are ignored (a typo cannot break a
    /// station, it just leaves that trigger off); `session` is accepted and
    /// means nothing extra.
    pub fn parse(s: &str) -> Self {
        let mut on = Self::default();
        for w in s.split(',').map(|w| w.trim().to_ascii_lowercase()) {
            match w.as_str() {
                "reset" => on.reset = true,
                "resume" => on.resume = true,
                "focus" => on.focus = true,
                "idle" => on.idle = true,
                "edge" => on.edge = true,
                "all" => {
                    on = Self {
                        reset: true,
                        resume: true,
                        focus: true,
                        idle: true,
                        edge: true,
                    }
                }
                _ => {}
            }
        }
        on
    }
    #[cfg(test)]
    pub fn any(&self) -> bool {
        self.reset || self.resume || self.focus || self.idle || self.edge
    }
}

/// Parse SH_REL_HOME_TO="x,y" (guest px) into the known-position seed target.
/// None (unset / malformed) falls back to the corner pin. See rel_bridge.rs.
pub fn parse_home_to(v: &str) -> Option<(i32, i32)> {
    let (a, b) = v.split_once(',')?;
    Some((a.trim().parse().ok()?, b.trim().parse().ok()?))
}
