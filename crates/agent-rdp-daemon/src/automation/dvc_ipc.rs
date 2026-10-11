//! DVC-based IPC for automation communication.
//!
//! Provides an async interface for sending requests to the PowerShell agent
//! over the DVC channel and receiving responses.

use std::sync::Arc;
use std::time::Duration;

use agent_rdp_protocol::AutomateRequest;
use tokio::sync::oneshot;
use tokio::time::timeout;
use tracing::{debug, error, trace};
use uuid::Uuid;

use super::dvc_channel::{DvcError, DvcProtocolMessage, DvcSendCommand, SharedDvcState};

/// Number of consecutive failures before suggesting reconnection.
const CONSECUTIVE_FAILURE_THRESHOLD: u32 = 3;

/// Deadline for requests that are expected to answer quickly.
const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

/// Snapshots walk the accessibility tree and may legitimately take longer than
/// the default; the agent bounds its own traversal well below this.
const SNAPSHOT_REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// Slack added on top of a request's own wait or process budget, so the daemon
/// never abandons a request before the agent's own deadline expires.
const RESPONSE_SLACK: Duration = Duration::from_secs(5);

/// Deadline to wait for a response, derived from what the request is allowed to
/// do on the agent side instead of from a single constant.
fn request_timeout(request: &AutomateRequest) -> Duration {
    match request {
        AutomateRequest::Snapshot { .. } => SNAPSHOT_REQUEST_TIMEOUT,
        AutomateRequest::WaitFor { timeout_ms, .. } => {
            Duration::from_millis(*timeout_ms).saturating_add(RESPONSE_SLACK)
        }
        AutomateRequest::Run { wait, timeout_ms, .. } => {
            if *wait {
                Duration::from_millis(*timeout_ms).saturating_add(RESPONSE_SLACK)
            } else {
                DEFAULT_REQUEST_TIMEOUT
            }
        }
        _ => DEFAULT_REQUEST_TIMEOUT,
    }
}

/// DVC-based IPC client for communicating with the PowerShell agent.
#[derive(Debug, Clone)]
pub struct DvcIpc {
    /// Shared state with the DVC processor.
    state: SharedDvcState,
    /// Lower bound for the per-request response deadline.
    timeout: Duration,
}

impl DvcIpc {
    /// Create a new DVC IPC client.
    pub fn new(state: SharedDvcState) -> Self {
        Self {
            state,
            timeout: DEFAULT_REQUEST_TIMEOUT,
        }
    }

    /// Raise the lower bound for every request deadline.
    pub fn set_timeout(&mut self, timeout: Duration) {
        self.timeout = timeout;
    }

    /// Get the number of consecutive failures.
    pub fn consecutive_failures(&self) -> u32 {
        self.state.lock().consecutive_failures
    }

    /// Reset the failure counter.
    fn reset_failures(&self) {
        self.state.lock().consecutive_failures = 0;
    }

    /// Increment the failure counter and return the new count.
    fn increment_failures(&self) -> u32 {
        let mut state = self.state.lock();
        state.consecutive_failures = state.consecutive_failures.saturating_add(1);
        state.consecutive_failures
    }

    /// Check if the DVC channel is ready (handshake received).
    pub fn is_ready(&self) -> bool {
        let state = self.state.lock();
        state.handshake.is_some() && state.channel_id.is_some()
    }

    /// Get the agent version from the handshake.
    pub fn agent_version(&self) -> Option<String> {
        let state = self.state.lock();
        state.handshake.as_ref().map(|h| h.version.clone())
    }

    /// Get the agent PID from the handshake.
    pub fn agent_pid(&self) -> Option<u32> {
        let state = self.state.lock();
        state.handshake.as_ref().map(|h| h.agent_pid)
    }

    /// Get the agent capabilities from the handshake.
    pub fn capabilities(&self) -> Vec<String> {
        let state = self.state.lock();
        state
            .handshake
            .as_ref()
            .map(|h| h.capabilities.clone())
            .unwrap_or_default()
    }

    /// Send a request to the PowerShell agent and wait for response.
    pub async fn send_request(&self, request: &AutomateRequest) -> anyhow::Result<serde_json::Value> {
        let request_id = Uuid::new_v4().to_string()[..8].to_string();

        // Convert AutomateRequest to command name and params
        let (command, params) = self.serialize_request(request)?;
        let command_name = command.clone();

        debug!(
            "Sending DVC request {}: command={}",
            request_id, command
        );

        // Create the protocol message
        let msg = DvcProtocolMessage::Request {
            id: request_id.clone(),
            command,
            params,
        };

        // Encode the message
        let encoded = Self::encode_message(&msg)?;

        // Create oneshot channel for response
        let (tx, rx) = oneshot::channel();

        // Register pending request and send via command channel
        let channel_id = {
            let mut state = self.state.lock();

            // Check if channel is open
            let channel_id = state
                .channel_id
                .ok_or_else(|| anyhow::anyhow!("DVC channel not open"))?;

            // Check if command sender is available
            let command_tx = state
                .command_tx
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("DVC command sender not configured"))?;

            // Send the data through the RDP session
            command_tx
                .send(DvcSendCommand {
                    channel_id,
                    data: encoded,
                })
                .map_err(|_| anyhow::anyhow!("Failed to send DVC command"))?;

            state.pending.insert(request_id.clone(), tx);
            channel_id
        };

        debug!("Sent DVC request on channel {}", channel_id);

        // Wait for response with timeout
        let deadline = self.timeout.max(request_timeout(request));
        let response = match timeout(deadline, rx).await {
            Ok(Ok(response)) => {
                self.reset_failures();
                response
            }
            Ok(Err(_)) => {
                // Channel closed
                let failures = self.increment_failures();
                if failures >= CONSECUTIVE_FAILURE_THRESHOLD {
                    error!(
                        "DVC request failed {} consecutive times. Channel may be dead.",
                        failures
                    );
                    anyhow::bail!(
                        "DVC channel appears to be dead ({} consecutive failures). \
                        The automation agent may have exited or be busy with a long \
                        request; relaunch it inside the session, or reconnect with \
                        --enable-win-automation.",
                        failures
                    );
                }
                anyhow::bail!("Response channel closed unexpectedly");
            }
            Err(_) => {
                // Timeout - remove pending request
                {
                    let mut state = self.state.lock();
                    state.pending.remove(&request_id);
                }
                let failures = self.increment_failures();
                if failures >= CONSECUTIVE_FAILURE_THRESHOLD {
                    error!(
                        "DVC request timed out {} consecutive times. Channel may be dead.",
                        failures
                    );
                    anyhow::bail!(
                        "DVC channel appears to be dead ({} consecutive failures). \
                        The automation agent may have exited or be busy with a long \
                        request; relaunch it inside the session, or reconnect with \
                        --enable-win-automation.",
                        failures
                    );
                }
                anyhow::bail!(
                    "Timeout waiting for DVC response after {:?} (command: {}). \
                    The agent may be busy with a long request; retry or raise --timeout.",
                    deadline, command_name
                );
            }
        };

        trace!("Received DVC response: success={}", response.success);

        if response.success {
            Ok(response.data.unwrap_or(serde_json::Value::Null))
        } else {
            let error = response.error.unwrap_or(DvcError {
                code: "unknown".to_string(),
                message: "Unknown error".to_string(),
            });
            anyhow::bail!("{}: {}", error.code, error.message)
        }
    }

    /// Serialize an AutomateRequest to command name and parameters.
    fn serialize_request(
        &self,
        request: &AutomateRequest,
    ) -> anyhow::Result<(String, serde_json::Value)> {
        // Serialize the request to get the command tag and data
        let json = serde_json::to_value(request)?;

        // The command is in the "op" field (serde tag), rest are params
        if let serde_json::Value::Object(mut obj) = json {
            let command = obj
                .remove("op")
                .and_then(|v| v.as_str().map(|s| s.to_string()))
                .ok_or_else(|| anyhow::anyhow!("Request missing op field"))?;

            Ok((command, serde_json::Value::Object(obj)))
        } else {
            anyhow::bail!("Failed to serialize request")
        }
    }

    /// Encode a message as JSON (DVC handles message framing).
    fn encode_message(msg: &DvcProtocolMessage) -> anyhow::Result<Vec<u8>> {
        let json = serde_json::to_string(msg)?;
        Ok(json.into_bytes())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_request_timeout_budgets() {
        assert_eq!(request_timeout(&AutomateRequest::Status), DEFAULT_REQUEST_TIMEOUT);

        let snapshot = AutomateRequest::Snapshot {
            interactive_only: false,
            compact: false,
            max_depth: 10,
            selector: None,
            focused: false,
        };
        assert_eq!(request_timeout(&snapshot), SNAPSHOT_REQUEST_TIMEOUT);

        let run_without_wait = AutomateRequest::Run {
            command: "Write-Output hi".to_string(),
            args: Vec::new(),
            wait: false,
            hidden: false,
            timeout_ms: 10_000,
        };
        assert_eq!(request_timeout(&run_without_wait), DEFAULT_REQUEST_TIMEOUT);

        let run_with_wait = AutomateRequest::Run {
            command: "Write-Output hi".to_string(),
            args: Vec::new(),
            wait: true,
            hidden: false,
            timeout_ms: 5_000,
        };
        assert_eq!(
            request_timeout(&run_with_wait),
            Duration::from_millis(5_000).saturating_add(RESPONSE_SLACK)
        );
    }
    use crate::automation::dvc_channel::new_shared_dvc_state;

    #[test]
    fn test_serialize_snapshot_request() {
        let state = new_shared_dvc_state();
        let ipc = DvcIpc::new(state);

        let request = AutomateRequest::Snapshot {
            interactive_only: true,
            compact: false,
            max_depth: 10,
            selector: None,
            focused: false,
        };

        let (command, params) = ipc.serialize_request(&request).unwrap();
        assert_eq!(command, "snapshot");
        assert_eq!(params["interactive_only"], true);
        assert_eq!(params["max_depth"], 10);
    }

    #[test]
    fn test_serialize_click_request() {
        let state = new_shared_dvc_state();
        let ipc = DvcIpc::new(state);

        let request = AutomateRequest::Click {
            selector: "@5".to_string(),
            double_click: false,
        };

        let (command, params) = ipc.serialize_request(&request).unwrap();
        assert_eq!(command, "click");
        assert_eq!(params["selector"], "@5");
    }

    #[test]
    fn test_is_ready_false_initially() {
        let state = new_shared_dvc_state();
        let ipc = DvcIpc::new(state);
        assert!(!ipc.is_ready());
    }
}
