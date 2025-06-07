let mousedown = false;
let transX = 0;
let transY = 0;
let startDragX = 0;
let startDragY = 0;
let id = 1;
let canvas;
let allNodes: TNode[];
let nodesById: Record<string, TNode>;

const rootNodeId = "root";

type TNode = {
  id: string;
  childrenIds: string[];
  text: string;
  leafCount?: number;
};

type TNodesById = Record<string, TNode>;

async function fetchData() {
  const json_data = await fetch("http://localhost:8080/trees.json", {
    mode: "cors",
  });
  allNodes = await json_data.json();

  nodesById = (() => {
    const res = {};
    allNodes.forEach((n) => {
      res[n.id] = n;
    });
    return res;
  })();

  addLeafCounts(rootNodeId);

  draw();
  createTextClient(allNodes, nodesById);
}

function createTextClient(allNodes: any[], nodesById: TNodesById) {
  const perms = generateAllPerms(nodesById);
  let currentConvoIndex = 0;
  renderCurrentConvo(perms[currentConvoIndex]);

  const prevButton = document.getElementById("prevButton");
  const nextButton = document.getElementById("nextButton");

  const prevListener = () => {
    if (currentConvoIndex === 0) {
      return;
    }

    currentConvoIndex -= 1;
    renderCurrentConvo(perms[currentConvoIndex]);
  };

  const nextListener = () => {
    if (currentConvoIndex === perms.length - 1) {
      return;
    }

    currentConvoIndex += 1;
    renderCurrentConvo(perms[currentConvoIndex]);
  };

  // remove prev listeners
  prevButton.removeEventListener("click", prevListener);
  nextButton.removeEventListener("click", nextListener);

  // add new listeners
  prevButton.addEventListener("click", prevListener);
  nextButton.addEventListener("click", nextListener);
}

function generateAllPerms(nodesById: TNodesById) {
  const allPaths: string[][] = [];
  const currentPath = [];

  function getPathForNodeId(nodeId: string) {
    currentPath.push(nodeId);
    const node = nodesById[nodeId];

    if (!node.childrenIds.length) {
      allPaths.push([...currentPath]);
      currentPath.pop();
    } else {
      node.childrenIds.forEach((childId) => getPathForNodeId(childId));
      currentPath.pop();
    }
  }

  getPathForNodeId("root");
  return allPaths;
}

function renderCurrentConvo(tweetIds: string[]) {
  const tweetList = document.getElementById("tweetList");
  const currentNodes = Array.from(tweetList.children);

  // clear the list
  for (const child of currentNodes) {
    tweetList.removeChild(child);
  }

  tweetIds.forEach((tweetId) => {
    const node = nodesById[tweetId];
    const container = document.createElement("div");
    container.classList.add("tweetContainer");
    container.innerText = node.text;
    tweetList.appendChild(container);
  });
}

function addLeafCounts(nodeId) {
  const node = nodesById[nodeId];
  const childrenCount = node.childrenIds.length;

  if (childrenCount === 0) {
    node.leafCount = 0;
    return 0;
  }

  const childrenLeafCount = node.childrenIds.reduce((accum, curr) => {
    const nCount = addLeafCounts(curr);
    return nCount + accum;
  }, 0);

  const totalLeafCount = childrenCount + childrenLeafCount;
  node.leafCount = totalLeafCount;

  return totalLeafCount;
}

// this mutates our nodes so each have a count of their children leaf nodes

const textBoxWidth = 250 + 40; // 250 for chars + 20px each side for padding
const textBoxHeight = 200;

const drawTree = ({ context, nodeId, isRoot, parentX, parentY }) => {
  const node = nodesById[nodeId];

  // Each call to drawTree draws all the children of a given node.
  // However, if this is the root node of the graph, it hasn't been drawn
  // yet, so draw it.
  if (isRoot) {
    context.beginPath();
    context.arc(0, 0, 15, 0, 2 * Math.PI);
    context.stroke();
    context.fillText(node.id, 0, 0);
  }

  const childNodeCount = node.leafCount;
  const spaceForLevel = (textBoxWidth + 20) * childNodeCount;
  const currTop = parentY + textBoxHeight + 120;
  let currLeft = parentX - spaceForLevel / 2; // go halfway left from center of parent

  // draw all the children in the space
  node.childrenIds.forEach((childNodeId) => {
    const childNode = nodesById[childNodeId];
    // add +1 to leafCount: even if a node has no children, it must take
    // up at least one space
    const spaceForChild =
      spaceForLevel * ((childNode.leafCount + 1) / childNodeCount);
    // if this node is a leaf node, we always draw it to the right of its
    // space (instead of under the parent, as it would be if we didn't do
    // this). Otherwise, we draw it in the middle of its given space, so
    // its children can fill to the edges of that space on the next level.
    const leftToDrawAt =
      childNode.leafCount === 0
        ? currLeft + spaceForChild
        : currLeft + spaceForChild / 2;

    context.strokeRect(
      leftToDrawAt - 0.5 * textBoxWidth, // center the box
      currTop,
      textBoxWidth,
      textBoxHeight
    );

    // draw line from parent to child
    context.beginPath();
    context.moveTo(leftToDrawAt, currTop);
    context.lineTo(parentX, parentY + textBoxHeight);
    context.stroke();

    drawTextInBox({ context, currTop, leftToDrawAt, text: childNode.text });

    // we draw from currLeft, then increment after drawing everything, for
    // the next loop
    currLeft += spaceForChild;

    drawTree({
      context,
      nodeId: childNodeId,
      isRoot: false,
      parentX: leftToDrawAt,
      parentY: currTop,
    });
  });
};

const textDrawWidth = textBoxWidth - 20;

const drawTextInBox = ({ context, currTop, leftToDrawAt, text }) => {
  let linesDrawn = 0;
  const words = text.split(/[\n\r\s]+/);
  let textToDraw = "";

  words.forEach((word, i) => {
    const nextText = i === 0 ? word : textToDraw + " " + word;
    if (i === words.length - 1) {
      // if we're at the end of our words, draw the line (even if it goes
      // over, because then I'd have to implement character-level wrapping
      // and I don't want to do that right now.)
      const leftOfText = leftToDrawAt + 10 - 0.5 * textBoxWidth;
      const topStart = currTop + 25 + linesDrawn * 20;
      context.fillText(nextText, leftOfText, topStart);
    } else if (context.measureText(nextText).width > textDrawWidth) {
      // if nextText pushes over, we need to draw the prev text (textToDraw)
      // then break the boundary-crossing word to the next line.

      // first clause gives us 10px of space from the box border, second
      // clause centers the box on the leftToDrawAt
      const leftOfText = leftToDrawAt + 10 - 0.5 * textBoxWidth;
      const topStart = currTop + 25 + linesDrawn * 20;
      context.fillText(textToDraw, leftOfText, topStart);
      textToDraw = word;
      linesDrawn += 1;
    } else {
      textToDraw = textToDraw + " " + word;
    }
  });
};

const draw = () => {
  if (!nodesById) {
    console.log("not drawing because no nodesById");
    return;
  }

  const context = canvas.getContext("2d");
  context.font = "16px serif";
  context.save();
  context.clearRect(0, 0, 2000, 2000);
  context.translate(transX, transY);
  context.strokeRect(0, 0, 150, 150);

  drawReticle(context);
  // for first call, we manually force the parent node to be at 0,0, since
  // we know that's where its going to be
  drawTree({
    context,
    nodeId: rootNodeId,
    isRoot: true,
    parentX: 0,
    parentY: 0,
  });

  context.restore();
};

// draw a simple "reticle" at the center of the canvas, with numbers on
// each axis so it is easier to think about where to place items &&
// remember the non-math-like coords system of the canvas grid
const drawReticle = (context) => {
  context.lineWidth = 1;
  context.strokeStyle = "#808080";
  context.beginPath();
  context.moveTo(-30, 0);
  context.lineTo(30, 0);
  context.stroke();

  context.beginPath();
  context.moveTo(0, -30);
  context.lineTo(0, 30);
  context.stroke();

  // chars are ~6px tall ish, just throw them on there where they kinda
  // center onto the reticle bars
  context.fillText("35", 35, 3);
  context.fillText("-35", -50, 3);
  context.fillText("35", -5, 40);
  context.fillText("-35", -9, -35);
  context.strokeStyle = "#000"; // black
};

document.addEventListener("DOMContentLoaded", () => {
  canvas = document.getElementById("mycanvas");

  const protoButton = document.getElementById("proto");
  const textButton = document.getElementById("text");
  const textApp = document.getElementById("textApp");

  protoButton.addEventListener("click", () => {
    protoButton.classList.add("current");
    canvas.classList.add("current");

    textApp.classList.remove("current");
    textButton.classList.remove("current");
  });

  textButton.addEventListener("click", () => {
    textButton.classList.add("current");
    textApp.classList.add("current");

    protoButton.classList.remove("current");
    canvas.classList.remove("current");
  });

  // set default state now to be the text app open
  textButton.classList.add("current");
  textApp.classList.add("current");

  fetchData();

  canvas.addEventListener("mousedown", (e) => {
    mousedown = true;
    startDragX = e.clientX - transX;
    startDragY = e.clientY - transY;
  });

  canvas.addEventListener("mouseup", () => {
    mousedown = false;
  });

  canvas.addEventListener("mousemove", (e) => {
    if (mousedown) {
      transX = e.clientX - startDragX;
      transY = e.clientY - startDragY;
      draw();
    }
  });

  document.addEventListener("keydown", function (e) {
    if (e.code === "KeyW") {
      transY += 50;
    } else if (e.code === "KeyS") {
      transY -= 50;
    } else if (e.code === "KeyA") {
      transX += 50;
    } else if (e.code === "KeyD") {
      transX -= 50;
    }
    draw();
  });

  // initial draw
  // draw()
});
