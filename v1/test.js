const allNodes = [
  { id: "a", childrenIds: ["b", "c", "e"] },
  { id: "b", childrenIds: [] },
  { id: "c", childrenIds: ["d"] },
  { id: "d", childrenIds: [] },
  { id: "e", childrenIds: ["f", "g"] },
  { id: "f", childrenIds: [] },
  { id: "g", childrenIds: ["h"] },
  { id: "h", childrenIds: [] },
];

const nodesById = (() => {
  const res = {};
  allNodes.forEach((n) => {
    res[n.id] = n;
  });
  return res;
})();

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

const res2 = addLeafCounts("a");
console.log(`----- res2: ${JSON.stringify(res2, null, 4)}`);

if (res2 !== 7) {
  throw new Error(`test res2 failed, expected count: 7, actual count: ${res2}`);
}
