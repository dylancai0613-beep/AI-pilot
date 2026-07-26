const form = document.querySelector("#compare-form");
const submitButton = document.querySelector("#submit-button");
const errorMessage = document.querySelector("#error-message");
const resultsSection = document.querySelector("#results-section");
const resultsContainer = document.querySelector("#results");
const routeSummary = document.querySelector("#route-summary");

const moneyFormatter = new Intl.NumberFormat("zh-CN", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

function showError(message) {
  errorMessage.textContent = message;
  errorMessage.hidden = false;
  resultsSection.hidden = true;
}

function createResultCard(option) {
  const card = document.createElement("article");
  card.className = "result-card";

  const topLine = document.createElement("div");
  topLine.className = "card-topline";

  const mode = document.createElement("h3");
  mode.className = "mode";
  mode.textContent = option.mode;
  topLine.append(mode);

  if (option.tag) {
    const tag = document.createElement("span");
    tag.className = "tag";
    tag.textContent = option.tag;
    topLine.append(tag);
  }

  const price = document.createElement("p");
  price.className = "price";
  price.textContent = `¥${moneyFormatter.format(option.total_cost)}`;
  const priceUnit = document.createElement("small");
  priceUnit.textContent = " 总价";
  price.append(priceUnit);

  const details = document.createElement("div");
  details.className = "details";

  const perPerson = document.createElement("div");
  perPerson.textContent = "人均 ";
  const perPersonValue = document.createElement("span");
  perPersonValue.textContent = `¥${moneyFormatter.format(option.per_person_cost)}`;
  perPerson.append(perPersonValue);

  const duration = document.createElement("div");
  duration.textContent = "预计耗时 ";
  const durationValue = document.createElement("span");
  durationValue.textContent = `${option.duration_minutes} 分钟`;
  duration.append(durationValue);

  details.append(perPerson, duration);
  card.append(topLine, price, details);
  return card;
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  errorMessage.hidden = true;
  submitButton.disabled = true;
  submitButton.textContent = "查询中…";

  const origin = document.querySelector("#origin").value;
  const destination = document.querySelector("#destination").value;
  const passengers = Number.parseInt(
    document.querySelector("#passengers").value,
    10,
  );

  try {
    const response = await fetch("/api/compare", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ origin, destination, passengers }),
    });

    const data = await response.json();
    if (!response.ok) {
      throw new Error(data.detail || "查询失败，请稍后重试");
    }

    resultsContainer.replaceChildren(
      ...data.options.map((option) => createResultCard(option)),
    );
    routeSummary.textContent = `${origin} → ${destination} · ${passengers} 人`;
    resultsSection.hidden = false;
  } catch (error) {
    showError(error instanceof Error ? error.message : "查询失败，请稍后重试");
  } finally {
    submitButton.disabled = false;
    submitButton.textContent = "开始比较";
  }
});
