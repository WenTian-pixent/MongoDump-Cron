// Discord index.js file to login and send message to channel
// Require the necessary discord.js classes
const dotenv = require("dotenv");
dotenv.config();
const fs = require("fs");
const { Client, Events, GatewayIntentBits } = require("discord.js");

if (process.argv.length <= 2) {
  console.error("Please provide the filename as an argument.");
  process.exit(0);
}
// Create a new client instance
const client = new Client({ intents: [GatewayIntentBits.Guilds] });
let fileContent = "";
try {
  fileContent = fs.readFileSync(`../mongodump-output/${process.argv?.[2]}`, {
    encoding: "utf8",
    flag: "r",
  });
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
  if (fileContent && !fileContent.includes("error")) {
    await sendMessageToChannel(
      process.env.CHANNEL_SUCCESS,
      `:white_check_mark: ## MongoDump ran successfully!\n**Filename:** ${
        process.argv?.[2] || "Invalid args file name"
      }\n**Content:** ${"\n```" + fileContent + "```" || "Invalid content"}`
    );
  } else {
    await sendMessageToChannel(
      process.env.CHANNEL_FAILED,
      `:x: ## MongoDump ran failed!\n**Filename:** ${
        process.argv?.[2] || "Invalid args file name"
      }\n**Content:** ${"\n```" + fileContent + "```" || "Invalid content"}`
    );
  }
});

// Log in to Discord with your client's token
client.login(process.env.TOKEN);
