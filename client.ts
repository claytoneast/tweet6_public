document.addEventListener("DOMContentLoaded", async () => {
  await fetchData();

  const refetchButton = document.getElementById("refetchButton");
  refetchButton.addEventListener("click", async () => {
    await fetchData();
  });

  const prevButton = document.getElementById("prevButton");
  const nextButton = document.getElementById("nextButton");

  prevButton.addEventListener("click", () => {
    const atFirstConvo = currentConvoIndex === 0;
    if (atFirstConvo) {
      return;
    }

    currentConvoIndex -= 1;
    showCurrentConversation();
  });

  nextButton.addEventListener("click", () => {
    const atLastConvo = currentConvoIndex === conversationChains.length - 1;
    if (atLastConvo) {
      return;
    }

    currentConvoIndex += 1;
    showCurrentConversation();
  });
});

type Tweet = {
  text: string;
  authorName: string;
  createdAt: string;
  photos?: string[];
};

type TConversationChains = string[][];
type ApiResponse = {
  allTweets: Tweet[];
  conversationChains: string[][];
  totalConversationsCount: number;
  lastRunAt: string;
};

let allTweets;
let conversationChains: TConversationChains;
let usernames: string[];
let currentUsernameIndex = 0;
let currentConvoIndex = 0;
let totalConversationsCount: number;

async function fetchData() {
  const loadingEl = document.getElementById("loadingState");
  loadingEl.classList.add("show");
  const errEl = document.getElementById("errorState");
  errEl.innerHTML = "";

  let response: Response;
  let body;

  try {
    response = await fetch("/data");
    body = await response.json();
  } catch (err) {
    errEl.classList.add("show");
    errEl.innerHTML =
      err?.message || err?.error || "Unexpected error occurred.";
    throw err;
  } finally {
    loadingEl.classList.remove("show");
  }

  const refetchButton = document.getElementById("refetchButton");

  if (body.data) {
    const respData: ApiResponse = body.data;

    allTweets = respData.allTweets;
    conversationChains = respData.conversationChains;
    totalConversationsCount = respData.totalConversationsCount;

    const { lastRunAt } = respData;
    const lastRunAtEl = document.getElementById("lastRunAt");
    lastRunAtEl.innerHTML = lastRunAt;

    refetchButton.classList.remove("show");
  } else {
    refetchButton.classList.add("show");
  }

  showCurrentConversation();
}

const urlRegex =
  /(https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&//=]*))/;

function showCurrentConversation() {
  const tweetList = document.getElementById("tweetList");
  tweetList.innerHTML = ""; // clear the current list

  if (!conversationChains || !conversationChains.length) {
    console.log("----- no conversationChains, or list is empty");
    return;
  }

  const currentConversationChain = conversationChains[currentConvoIndex];
  if (!currentConversationChain) {
    console.log("----- no currentConversationChain");
    return;
  }

  const totalCountEl = document.getElementById("totalConversationsCount");
  totalCountEl.innerHTML = `${(
    currentConvoIndex + 1
  ).toString()}/${totalConversationsCount.toString()} conversations`;

  currentConversationChain.forEach((tweetId) => {
    const tweetData = allTweets[tweetId];

    const container = document.createElement("div");
    container.classList.add("tweetContainer");

    const authorNameNode = document.createElement("b");
    authorNameNode.innerText = tweetData.authorName;

    const tweetTextNode = document.createElement("p");

    const initialText = tweetData.text;
    const matches = initialText.match(urlRegex);
    if (matches) {
      const fullUrlMatch = matches[0];
      const nextText = initialText.replace(fullUrlMatch, "");
      tweetTextNode.innerText = nextText;

      const linkNode = document.createElement("a");
      linkNode.innerText = fullUrlMatch;
      linkNode.href = fullUrlMatch;
      tweetTextNode.appendChild(linkNode);
    } else {
      tweetTextNode.innerText = initialText;
    }

    const createdAtNode = document.createElement("i");
    createdAtNode.innerText = tweetData.createdAt;

    let photosNode;
    if (tweetData.photos && tweetData.photos.length) {
      photosNode = document.createElement("div");
      photosNode.classList.add("photos");
      tweetData.photos.forEach((photoUrl) => {
        const photoNode = document.createElement("img");
        photoNode.src = photoUrl;
        photosNode.appendChild(photoNode);
      });
      // <img src="img_girl.jpg" alt="Girl in a jacket" width="500" height="600">
    }

    container.appendChild(authorNameNode);
    container.appendChild(tweetTextNode);
    if (photosNode) {
      container.appendChild(photosNode);
    }
    container.appendChild(createdAtNode);

    tweetList.appendChild(container);
  });
}
