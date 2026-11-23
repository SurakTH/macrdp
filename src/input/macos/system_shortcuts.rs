//! Reuse the trusted System Events path without starting osascript for each tap.
use super::CtrlArrowAction;
use core_foundation::{
    array::CFArray,
    base::{CFType, CFTypeRef, TCFType},
    boolean::CFBoolean,
    dictionary::CFDictionary,
    number::CFNumber,
    string::{CFString, CFStringRef},
};
use core_graphics::{
    display::CGDisplay,
    event::CGEvent,
    event_source::{CGEventSource, CGEventSourceStateID},
    geometry::{CGPoint, CGRect},
};
use std::{
    io::{self, BufRead, BufReader, Write},
    process::{Child, ChildStdin, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, SyncSender},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};

const IDLE_TIMEOUT: Duration = Duration::from_secs(60);
const REPLY_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_QUEUE_AGE: Duration = Duration::from_secs(1);
const COMPLETED: &str = "macrdp-shortcut-complete";
const FAILED: &str = "macrdp-shortcut-error: ";

pub(super) enum Shortcut {
    Prepare,
    ControlArrow(CtrlArrowAction, Option<ShortcutDisplay>),
    CommandSpace(Option<ShortcutDisplay>),
}

#[derive(Clone, Copy)]
pub(super) struct ShortcutDisplay {
    pub(super) id: u32,
    pub(super) last_pointer: CGPoint,
}

impl ShortcutDisplay {
    pub(super) fn route(self) -> bool {
        let display = CGDisplay::new(self.id);
        let bounds = display.bounds();
        if !display.is_active() || bounds.size.width <= 0.0 || bounds.size.height <= 0.0 {
            tracing::debug!(display_id = self.id, "Shortcut target display inactive");
            return false;
        }
        let current = CGEventSource::new(CGEventSourceStateID::CombinedSessionState)
            .and_then(CGEvent::new)
            .ok()
            .map(|event| event.location());
        let Some(point) = target_pointer(bounds, current, self.last_pointer) else {
            return true;
        };
        match CGDisplay::warp_mouse_cursor_position(point) {
            Ok(()) => {
                tracing::debug!(
                    display_id = self.id,
                    "Routed shortcut pointer to virtual display"
                );
                true
            }
            Err(error) => {
                tracing::warn!(
                    display_id = self.id,
                    ?error,
                    "Could not route shortcut to virtual display"
                );
                false
            }
        }
    }
}

fn target_pointer(bounds: CGRect, current: Option<CGPoint>, previous: CGPoint) -> Option<CGPoint> {
    let contains = |point: CGPoint| {
        point.x >= bounds.origin.x
            && point.x < bounds.origin.x + bounds.size.width
            && point.y >= bounds.origin.y
            && point.y < bounds.origin.y + bounds.size.height
    };
    if current.is_some_and(contains) {
        return None;
    }
    Some(if contains(previous) {
        previous
    } else {
        CGPoint::new(
            bounds.origin.x + bounds.size.width / 2.0,
            bounds.origin.y + bounds.size.height / 2.0,
        )
    })
}

pub(super) struct Dispatcher {
    request: SyncSender<(Shortcut, Instant)>,
    closed: Arc<AtomicBool>,
}

impl Dispatcher {
    pub(super) fn start() -> io::Result<Self> {
        let (request, pending) = mpsc::sync_channel(8);
        let closed = Arc::new(AtomicBool::new(false));
        let worker_closed = closed.clone();
        thread::Builder::new()
            .name("macrdp-system-shortcuts".into())
            .spawn(move || dispatch(pending, &worker_closed))?;
        Ok(Self { request, closed })
    }

    pub(super) fn send(&self, shortcut: Shortcut) {
        if let Err(error) = self.request.try_send((shortcut, Instant::now())) {
            tracing::debug!(%error, "System shortcut queue busy");
        }
    }
}

impl Drop for Dispatcher {
    fn drop(&mut self) {
        self.closed.store(true, Ordering::Release);
    }
}

fn dispatch(pending: Receiver<(Shortcut, Instant)>, closed: &AtomicBool) {
    let mut process = None;
    loop {
        let (shortcut, queued) = match pending.recv_timeout(IDLE_TIMEOUT) {
            Ok(value) => value,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                process = None;
                continue;
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        };
        if closed.load(Ordering::Acquire) {
            break;
        }
        if queued.elapsed() > MAX_QUEUE_AGE {
            continue;
        }

        let (keycode, modifier, label, display) = match shortcut {
            Shortcut::Prepare => {
                if process.is_none() {
                    process = ScriptProcess::start().ok();
                }
                continue;
            }
            Shortcut::ControlArrow(action, display) => {
                (action as u16, "control", "Ctrl+Arrow", display)
            }
            Shortcut::CommandSpace(_) if cmd_space_selects_input_source() => {
                (49, "command", "Cmd+Space", None)
            }
            Shortcut::CommandSpace(display) => {
                objc2::rc::autoreleasepool(|_| super::invoke_spotlight(display));
                continue;
            }
        };
        let script = format!(
            r#"tell application "System Events" to key code {keycode} using {{{modifier} down}}"#
        );
        // A known-dead child has received no new command and can be replaced.
        if process
            .as_mut()
            .is_some_and(|p: &mut ScriptProcess| !p.running())
        {
            process = None;
        }
        let helper_reused = process.is_some();
        if process.is_none() {
            match ScriptProcess::start() {
                Ok(child) => process = Some(child),
                Err(error) => {
                    tracing::debug!(%error, "Reusable System Events helper unavailable");
                    if display.is_none_or(ShortcutDisplay::route) {
                        super::run_system_events_key(script, label);
                    }
                    continue;
                }
            }
        }
        if closed.load(Ordering::Acquire) || !display.is_none_or(ShortcutDisplay::route) {
            continue;
        }
        if let Some(child) = process.as_mut() {
            let started = Instant::now();
            let target_display_id = display.map(|target| target.id);
            match child.run(&script) {
                Ok(Ok(())) => tracing::debug!(
                    shortcut = label,
                    keycode,
                    display_id = target_display_id,
                    queued_ms = started.duration_since(queued).as_millis() as u64,
                    execution_ms = started.elapsed().as_millis() as u64,
                    helper_reused,
                    "System Events shortcut completed"
                ),
                Ok(Err(error)) => {
                    tracing::warn!(shortcut = label, keycode, %error, "System Events shortcut failed");
                }
                Err(error) => {
                    // The action may already have happened. Replace the helper
                    // for the next key press without replaying this shortcut.
                    tracing::warn!(shortcut = label, keycode, %error, "Lost System Events helper");
                    process = None;
                }
            }
        }
    }
}

struct ScriptProcess {
    child: Child,
    input: ChildStdin,
    reply: Receiver<Result<(), String>>,
}

impl ScriptProcess {
    fn start() -> io::Result<Self> {
        let mut child = Command::new("/usr/bin/osascript")
            .arg("-i")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()?;
        let input = child.stdin.take().expect("piped stdin");
        let errors = child.stderr.take().expect("piped stderr");
        let (completed, reply) = mpsc::sync_channel(1);
        if let Err(error) = thread::Builder::new()
            .name("macrdp-system-shortcut-replies".into())
            .spawn(move || {
                for line in BufReader::new(errors).lines().map_while(Result::ok) {
                    let line = line.trim();
                    let result = if line == COMPLETED {
                        Some(Ok(()))
                    } else {
                        line.strip_prefix(FAILED)
                            .map(|message| Err(message.to_owned()))
                    };
                    if let Some(result) = result {
                        if completed.send(result).is_err() {
                            break;
                        }
                    }
                }
            })
        {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error);
        }
        Ok(Self {
            child,
            input,
            reply,
        })
    }

    fn running(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    fn run(&mut self, script: &str) -> io::Result<Result<(), String>> {
        // Interactive results and uncaught script errors go to buffered
        // stdout. Log exactly one explicit result to stderr instead.
        writeln!(
            self.input,
            "try\n{script}\nlog \"{COMPLETED}\"\non error detail\nlog (\"{FAILED}\" & detail)\nend try"
        )?;
        self.reply
            .recv_timeout(REPLY_TIMEOUT)
            .map_err(|error| match error {
                mpsc::RecvTimeoutError::Timeout => io::ErrorKind::TimedOut.into(),
                mpsc::RecvTimeoutError::Disconnected => io::ErrorKind::BrokenPipe.into(),
            })
    }
}

impl Drop for ScriptProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFPreferencesCopyAppValue(key: CFStringRef, app: CFStringRef) -> CFTypeRef;
}

fn cmd_space_selects_input_source() -> bool {
    let key = CFString::from_static_string("AppleSymbolicHotKeys");
    let app = CFString::from_static_string("com.apple.symbolichotkeys");
    // SAFETY: The Copy API returns an owned property list or null.
    let bindings = unsafe {
        let value = CFPreferencesCopyAppValue(key.as_concrete_TypeRef(), app.as_concrete_TypeRef());
        if value.is_null() {
            return false;
        }
        CFType::wrap_under_create_rule(value).downcast_into::<CFDictionary>()
    };
    bindings.is_some_and(|list| {
        ["60", "61"]
            .iter()
            .any(|id| is_cmd_space(&list, id) == Some(true))
    })
}

fn property(dict: &CFDictionary, key: &str) -> Option<CFType> {
    let key = CFString::new(key);
    let value = *dict.find(key.as_CFTypeRef())?;
    // SAFETY: The property-list dictionary holds a Core Foundation object.
    Some(unsafe { CFType::wrap_under_get_rule(value) })
}

fn is_cmd_space(bindings: &CFDictionary, id: &str) -> Option<bool> {
    let entry = property(bindings, id)?.downcast_into::<CFDictionary>()?;
    let enabled = bool::from(property(&entry, "enabled")?.downcast_into::<CFBoolean>()?);
    let value = property(&entry, "value")?.downcast_into::<CFDictionary>()?;
    let parameters = property(&value, "parameters")?.downcast_into::<CFArray>()?;
    let number = |index| {
        let value = *parameters.get(index)?;
        // SAFETY: The array retains this property-list object.
        unsafe { CFType::wrap_under_get_rule(value) }
            .downcast_into::<CFNumber>()?
            .to_i32()
    };
    // These are the two input-source entries. Match a plain Command+Space
    // binding only; custom chords and disabled entries keep their old route.
    Some(enabled && number(1)? == 49 && number(2)? == 1 << 20)
}

#[cfg(test)]
mod tests {
    use super::*;
    use core_graphics::geometry::CGSize;

    #[test]
    fn shortcut_pointer_stays_on_target_and_recovers_after_layout_changes() {
        let bounds = CGRect::new(&CGPoint::new(-1920.0, 100.0), &CGSize::new(1920.0, 1080.0));
        let remembered = CGPoint::new(-1400.0, 250.0);
        assert!(target_pointer(bounds, Some(remembered), CGPoint::new(0.0, 0.0)).is_none());

        let outside = Some(CGPoint::new(0.0, 250.0));
        let remembered_target = target_pointer(bounds, outside, remembered).unwrap();
        assert_eq!((remembered_target.x, remembered_target.y), (-1400.0, 250.0));

        let center = target_pointer(bounds, outside, CGPoint::new(300.0, 250.0)).unwrap();
        assert_eq!((center.x, center.y), (-960.0, 640.0));
    }

    #[test]
    fn interactive_worker_reuses_process_after_multiple_requests() {
        let mut process = ScriptProcess::start().unwrap();
        let pid = process.child.id();
        process.run("set fixture to 1 + 1").unwrap().unwrap();
        assert!(process.run("error \"test error\"").unwrap().is_err());
        process.run("set fixture to 2 + 2").unwrap().unwrap();
        assert_eq!(process.child.id(), pid);
    }

    #[test]
    fn only_an_enabled_plain_cmd_space_binding_switches_input_source() {
        use core_foundation::{data::CFData, propertylist};
        let xml = br#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>60</key><dict><key>enabled</key><true/><key>value</key><dict><key>parameters</key><array><integer>32</integer><integer>49</integer><integer>1048576</integer></array></dict></dict>
<key>61</key><dict><key>enabled</key><false/><key>value</key><dict><key>parameters</key><array><integer>32</integer><integer>49</integer><integer>1048576</integer></array></dict></dict>
<key>62</key><dict><key>enabled</key><true/><key>value</key><dict><key>parameters</key><array><integer>32</integer><integer>49</integer><integer>1179648</integer></array></dict></dict>
</dict></plist>"#;
        let (value, _) = propertylist::create_with_data(CFData::from_buffer(xml), 0).unwrap();
        let list = unsafe { CFType::wrap_under_create_rule(value) }
            .downcast_into::<CFDictionary>()
            .unwrap();
        assert_eq!(is_cmd_space(&list, "60"), Some(true));
        assert_eq!(is_cmd_space(&list, "61"), Some(false));
        assert_eq!(is_cmd_space(&list, "62"), Some(false));
        assert_eq!(is_cmd_space(&list, "missing"), None);
    }
}
