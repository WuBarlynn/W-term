use super::*;
use crate::api::client::{AuthChallenge, AuthPrompt};
use tokio::sync::oneshot;
struct Waiting {
    challenge: AuthChallenge,
    reply: oneshot::Sender<Zeroizing<Vec<String>>>,
}
fn waiting() -> &'static Mutex<HashMap<String, Waiting>> {
    static ITEMS: OnceLock<Mutex<HashMap<String, Waiting>>> = OnceLock::new();
    ITEMS.get_or_init(Default::default)
}
pub async fn clear(id: &str) {
    waiting().lock().await.remove(id);
}
pub async fn challenge(id: &str) -> Option<AuthChallenge> {
    waiting().lock().await.get(id).map(|w| w.challenge.clone())
}
pub async fn respond(id: &str, challenge_id: &str, answers: Vec<String>) -> Result<()> {
    let answers = Zeroizing::new(answers);
    let mut items = waiting().lock().await;
    let current = items.get(id).context("认证问题已失效")?;
    anyhow::ensure!(current.challenge.id == challenge_id, "认证问题已变化");
    anyhow::ensure!(
        answers.len() == current.challenge.prompts.len()
            && answers.iter().all(|a| a.len() <= 16384),
        "认证回答数量或长度无效"
    );
    let current = items.remove(id).context("认证问题已失效")?;
    current
        .reply
        .send(answers)
        .map_err(|_| anyhow!("认证已结束"))
}
async fn ask(
    id: &str,
    name: String,
    instructions: String,
    prompts: Vec<client::Prompt>,
    wait: Duration,
) -> Result<Zeroizing<Vec<String>>> {
    anyhow::ensure!(
        prompts.len() <= 16
            && name.len() <= 4096
            && instructions.len() <= 16384
            && prompts.iter().all(|p| p.prompt.len() <= 4096),
        "服务器认证问题超过限制"
    );
    let (tx, rx) = oneshot::channel();
    let challenge = AuthChallenge {
        id: Uuid::new_v4().to_string(),
        name,
        instructions,
        prompts: prompts
            .into_iter()
            .map(|p| AuthPrompt {
                label: p.prompt,
                echo: p.echo,
            })
            .collect(),
    };
    waiting().lock().await.insert(
        id.into(),
        Waiting {
            challenge,
            reply: tx,
        },
    );
    let result = tokio::time::timeout(wait, rx)
        .await
        .context("等待认证回答超时")
        .and_then(|r| r.context("认证已取消"));
    clear(id).await;
    result
}
pub async fn authenticate(id: &str, handle: &mut Transport, username: &str) -> Result<()> {
    use client::KeyboardInteractiveAuthResponse as Response;
    let mut response = tokio::time::timeout(
        Duration::from_secs(20),
        handle.authenticate_keyboard_interactive_start(username, None),
    )
    .await
    .context("交互式认证响应超时")??;
    for _ in 0..8 {
        match response {
            Response::Success => return Ok(()),
            Response::Failure { .. } => bail!("交互式认证被拒绝，请检查验证码或服务器认证要求"),
            Response::InfoRequest {
                name,
                instructions,
                prompts,
            } => {
                let mut answers =
                    ask(id, name, instructions, prompts, Duration::from_secs(120)).await?;
                response = tokio::time::timeout(
                    Duration::from_secs(20),
                    handle.authenticate_keyboard_interactive_respond(std::mem::take(&mut *answers)),
                )
                .await
                .context("交互式认证响应超时")??;
            }
        }
    }
    if matches!(response, Response::Success) {
        return Ok(());
    }
    bail!("交互式认证轮数超过限制")
}
#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn challenge_binding_replay_limits_and_timeout() -> Result<()> {
        let id = Uuid::new_v4().to_string();
        let task_id = id.clone();
        let task = tokio::spawn(async move {
            ask(
                &task_id,
                "Test".into(),
                "".into(),
                vec![client::Prompt {
                    prompt: "OTP".into(),
                    echo: false,
                }],
                Duration::from_secs(2),
            )
            .await
        });
        let v = loop {
            if let Some(v) = challenge(&id).await {
                break v;
            }
            tokio::task::yield_now().await;
        };
        assert!(respond(&id, "stale", vec!["123".into()]).await.is_err());
        assert!(respond(&id, &v.id, vec![]).await.is_err());
        assert!(respond("wrong-connection", &v.id, vec!["123".into()])
            .await
            .is_err());
        respond(&id, &v.id, vec!["123".into()]).await?;
        assert!(respond(&id, &v.id, vec!["123".into()]).await.is_err());
        assert_eq!(task.await??[0], "123");
        assert!(
            ask(&id, "".into(), "".into(), vec![], Duration::from_millis(5))
                .await
                .is_err()
        );
        assert!(challenge(&id).await.is_none());
        assert!(ask(
            &id,
            "x".repeat(4097),
            "".into(),
            vec![],
            Duration::from_millis(5)
        )
        .await
        .is_err());
        Ok(())
    }
}
