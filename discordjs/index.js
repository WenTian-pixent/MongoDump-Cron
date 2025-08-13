// Discord index.js file to login and send message to channel
// Require the necessary discord.js classes
import dotenv from "dotenv";
dotenv.config();
import fs from "fs";
import { Client, Events, GatewayIntentBits } from "discord.js";

if (process.argv.length <= 2) {
  console.error("Please provide the filename as an argument.");
  process.exit(0);
}

// Create a new client instance
const client = new Client({ intents: [GatewayIntentBits.Guilds] });
const fileContents = [];
try {
  for (let i = 2; i < process.argv.length; i++) {
    const fileContent = fs.readFileSync(
      new URL(process.argv?.[i], import.meta.url),
      {
        encoding: "utf8",
        flag: "r",
      }
    );
    fileContents.push({ fileName: process.argv[i], fileContent });
  }
} catch {
  console.error("Error reading file");
  process.exit(0);
}

async function sendMessageToChannel(channelId, message) {
  const channel = await client.channels.fetch(channelId);
  if (channel) {
    channel.send(message);
    console.log("Message sent!");
    client.destroy(); // Optional: logout after sending
  } else {
    console.error("Channel not found!");
  }
}

// When the client is ready, run this code (only once).
// The distinction between `client: Client<boolean>` and `readyClient: Client<true>` is important for TypeScript developers.
// It makes some properties non-nullable.
client.once(Events.ClientReady, async (readyClient) => {
  console.log(`Ready! Logged in as ${readyClient.user.tag}`);
  let message = "";
  let errorMessage = "";
  for (const fileObj of fileContents) {
    if (fileObj.fileContent && !fileObj.fileContent.includes("error")) {
      message += `:white_check_mark: ## MongoDump ran successfully!\n**Filename:** ${
        fileObj.fileName || "Invalid args file name"
      }\n**Content:** ${
        "\n```" + fileObj.fileContent + "```" || "Invalid content"
      } \n`;
    } else {
      errorMessage += `:x: ## MongoDump ran failed!\n**Filename:** ${
        fileObj.fileName || "Invalid args file name"
      }\n**Content:** ${
        "\n```" + fileObj.fileContent + "```" || "Invalid content"
      } \n`;
    }
  }
  if (message) {
    await sendMessageToChannel(process.env.CHANNEL_SUCCESS, message);
  }
  if (errorMessage) {
    await sendMessageToChannel(process.env.CHANNEL_FAILED, errorMessage);
  }
});

// Log in to Discord with your client's token
client.login(process.env.TOKEN);
