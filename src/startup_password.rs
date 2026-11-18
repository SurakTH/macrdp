//! Wait for updated Keychain credentials without repeatedly authenticating a
//! known-bad password under launchd's KeepAlive policy.

use anyhow::{anyhow, Result};
use std::time::Duration;
use zeroize::Zeroizing;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Waiting {
    Missing,
    Rejected,
}

enum Attempt {
    Ready(Zeroizing<String>),
    Wait(Waiting, anyhow::Error),
}

#[derive(Default)]
struct PasswordGate {
    rejected: Option<Zeroizing<String>>,
}

impl PasswordGate {
    fn check(
        &mut self,
        read: Result<Zeroizing<String>>,
        verify: impl FnOnce(&str) -> Result<()>,
    ) -> Attempt {
        let password = match read {
            Ok(password) => password,
            Err(error) => return Attempt::Wait(Waiting::Missing, error),
        };
        if self.rejected.as_deref() == Some(&*password) {
            return Attempt::Wait(
                Waiting::Rejected,
                anyhow!("stored account password has not changed"),
            );
        }
        match verify(&password) {
            Ok(()) => Attempt::Ready(password),
            Err(error) => {
                self.rejected = Some(password);
                Attempt::Wait(Waiting::Rejected, error)
            }
        }
    }
}

pub(crate) async fn read_and_verify(
    park: bool,
    mut read: impl FnMut() -> Result<Zeroizing<String>>,
    mut verify: impl FnMut(&str) -> Result<()>,
) -> Result<Zeroizing<String>> {
    let mut gate = PasswordGate::default();
    let mut reported = None;
    loop {
        match gate.check(read(), &mut verify) {
            Attempt::Ready(password) => {
                if reported.is_some() {
                    tracing::info!(
                        credential_process = std::process::id(),
                        credential_status = "recovered",
                        "Keychain password accepted; continuing startup"
                    );
                }
                return Ok(password);
            }
            Attempt::Wait(reason, error) if park => {
                if reported != Some(reason) {
                    tracing::warn!(credential_process = std::process::id(),
                        credential_status = "waiting", %error, ?reason, "Waiting for a valid Keychain password");
                    reported = Some(reason);
                }
                tokio::time::sleep(Duration::from_secs(30)).await;
            }
            Attempt::Wait(_, error) => return Err(error),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_entry_does_not_clear_rejection_and_changed_value_is_checked() {
        let mut gate = PasswordGate::default();
        assert!(matches!(
            gate.check(Ok(Zeroizing::new("old".into())), |_| Err(anyhow!(
                "rejected"
            ))),
            Attempt::Wait(Waiting::Rejected, _)
        ));
        assert!(matches!(
            gate.check(Err(anyhow!("missing")), |_| panic!("no password to check")),
            Attempt::Wait(Waiting::Missing, _)
        ));
        assert!(matches!(
            gate.check(Ok(Zeroizing::new("old".into())), |_| panic!(
                "already rejected"
            )),
            Attempt::Wait(Waiting::Rejected, _)
        ));
        assert!(matches!(
            gate.check(Ok(Zeroizing::new("new".into())), |password| {
                assert_eq!(password, "new");
                Ok(())
            }),
            Attempt::Ready(_)
        ));
    }

    #[tokio::test]
    async fn terminal_mode_returns_first_error() {
        let result = read_and_verify(
            false,
            || Ok(Zeroizing::new("old".into())),
            |_| Err(anyhow!("rejected")),
        )
        .await;
        assert_eq!(result.err().unwrap().to_string(), "rejected");
    }
}
