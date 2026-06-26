use std::{net::SocketAddr, ops::Add, pin::pin, str::FromStr, time::Duration};

use chrono::prelude::Utc;
use clap::{Parser, Subcommand};
use futures_util::{FutureExt, SinkExt, StreamExt, select};
use http::Uri;
use tokio::{
    net::{TcpListener, TcpStream},
    sync::broadcast::{self, Sender},
    time::sleep,
};
use tokio_util::sync::CancellationToken;
use tokio_websockets::{ClientBuilder, Error, Message, ServerBuilder};

#[derive(Subcommand, Debug)]
enum Commands {
    Daemon,
    Command { command: String },
}

/// Simple program to greet a person
#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,

    #[arg(short, long)]
    port: u16,

    #[arg(long)]
    shutdown_seconds: u64,

    #[arg(long)]
    stop_systemd_service: Option<String>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Daemon => daemon(cli.port, Duration::from_secs(cli.shutdown_seconds)).await?,
        Commands::Command { command } => {
            println!("Establishing connection");
            let uri = Uri::from_str(format!("ws://127.0.0.1:{}", cli.port).as_str()).unwrap();
            let (mut client, _) = ClientBuilder::from_uri(uri).connect().await?;

            println!("Sending command");
            client.send(Message::text(command)).await?;

            println!("Waiting for server to close connection");
            while let Some(Ok(msg)) = client.next().await {
                if let Some(text) = msg.as_text() {
                    println!("SERVER: {}", text);
                }
            }
        }
    }

    Ok(())
}

async fn daemon(port: u16, shutdown_delay: Duration) -> Result<(), Error> {
    let (tx, _) = broadcast::channel::<()>(1);
    let listener = TcpListener::bind(format!("127.0.0.1:{}", port)).await?;
    let cancel_token = CancellationToken::new();
    let mut ctrl_c = pin!(tokio::signal::ctrl_c().fuse());

    println!("Server started");
    loop {
        let mut cancellation = pin!(cancel_token.cancelled().fuse());
        let mut accept = pin!(listener.accept().fuse());

        select! {
          result = accept => handle_socket(result, &tx, shutdown_delay, cancel_token.clone()).await?,
          _ = cancellation => {
            break;
          }
          _ = ctrl_c => {
            println!("Received Ctrl+C");
            break;
          }
        }
    }

    println!("Shutting down...");
    Ok(())
}

async fn handle_socket(
    result: std::io::Result<(TcpStream, SocketAddr)>,
    shutdown_warning_sender: &Sender<()>,
    shutdown_duration: Duration,
    cancellation_token: CancellationToken,
) -> Result<(), Error> {
    let (socket, _) = result?;
    let (_request, mut ws_stream) = ServerBuilder::new().accept(socket).await?;
    if let Some(Ok(msg)) = ws_stream.next().await {
        if let Some(text) = msg.as_text() {
            match text {
                "shutdown" => {
                    println!("Shutdown signal received");
                    if shutdown_warning_sender.receiver_count() > 0 {
                        if let Err(err) = shutdown_warning_sender.send(()) {
                            eprintln!("Failed to send shutdown warning signal: {}", err);
                        } else {
                            println!("Awaiting timeout");
                            sleep(shutdown_duration).await;
                        }
                    } else {
                        println!("No listener registered");
                    }

                    cancellation_token.cancel();
                }
                "register_shutdown_warning" => {
                    let mut receiver = shutdown_warning_sender.subscribe();
                    tokio::spawn(async move {
                        match receiver.recv().await {
                            Ok(_) => {
                                let shutdown_timestamp = Utc::now().add(shutdown_duration);
                                let iso8601 = shutdown_timestamp.to_rfc3339();
                                let command = format!("shutdown_at:{}", iso8601);
                                if let Err(error) = ws_stream.send(Message::text(command)).await {
                                    eprintln!(
                                        "Error sending shutdown message, short circuiting delay: {}",
                                        error
                                    );
                                    cancellation_token.cancel();
                                }
                            }
                            Err(err) => {
                                eprintln!("Shutdown warning registration receive error: {}", err)
                            }
                        }
                    });
                }
                _ => {
                    let message = format!("Unrecognized command: {}", text);
                    println!("{}", message);
                    ws_stream.send(Message::text(message)).await?
                }
            }
        }
    }

    Ok(())
}
