document.addEventListener('DOMContentLoaded', () => {
  const promptInput = document.getElementById('prompt');
  const sendBtn = document.getElementById('send-btn');
  const outputContainer = document.getElementById('output-container');
  const maxTokensSlider = document.getElementById('max_tokens');
  const tempSlider = document.getElementById('temperature');
  const valTokens = document.getElementById('val-tokens');
  const valTemp = document.getElementById('val-temp');
  const modelInput = document.getElementById('model');

  // Fetch dynamic config from server environment variables
  fetch('/api/config')
    .then(res => res.json())
    .then(data => {
      if (data.bucketName) {
        modelInput.value = `gs://${data.bucketName}/gemma-3-12b-it`;
      }
    })
    .catch(console.error);

  // Update slider values
  maxTokensSlider.addEventListener('input', (e) => valTokens.textContent = e.target.value);
  tempSlider.addEventListener('input', (e) => valTemp.textContent = e.target.value);

  async function generate() {
    const prompt = promptInput.value.trim();
    if (!prompt) return;

    // Clear input immediately
    promptInput.value = '';

    // UI Updates
    sendBtn.disabled = true;
    sendBtn.innerHTML = '<span class="loader"></span> Generating...'; // Simple text for now

    // Clear previous output if new request (or append? Let's clear for now to keep it simple, or maybe append user prompt)
    // For this simple specific tool, typically you want to see the result.
    // Let's make it chat-like: Append User, then Append Bot with streaming.

    // Remove placeholder
    const placeholder = outputContainer.querySelector('.placeholder');
    if (placeholder) placeholder.remove();

    // Append User Prompt
    appendMessage('User', prompt);

    // Prepare Bot Message container
    const botMessageDiv = appendMessage('AI', '');

    try {
      // Format prompt for Gemma Instruct model
      const gemmaPrompt = `<start_of_turn>user\n${prompt}<end_of_turn>\n<start_of_turn>model\n`;

      const response = await fetch('/v1/completions', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          model: modelInput.value,
          prompt: gemmaPrompt,
          max_tokens: parseInt(maxTokensSlider.value),
          temperature: parseFloat(tempSlider.value),
          stream: false // vLLM supports streaming, but let's start simple.
        })
      });

      if (!response.ok) {
        const errText = await response.text();
        throw new Error(`Error: ${response.statusText} - ${errText}`);
      }

      const data = await response.json();
      const text = data.choices[0].text;

      // Typewriter effect or just show it
      botMessageDiv.textContent = text;

    } catch (error) {
      botMessageDiv.textContent = `Error: ${error.message}`;
      botMessageDiv.style.color = '#ff6b6b';
    } finally {
      sendBtn.disabled = false;
      sendBtn.innerHTML = `<span>Generate</span>
                        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                            <path d="M22 2L11 13" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                            <path d="M22 2L15 22L11 13L2 9L22 2Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                        </svg>`;
    }
  }

  function appendMessage(role, text) {
    const msgDiv = document.createElement('div');
    msgDiv.className = `message ${role.toLowerCase()}`;
    msgDiv.style.marginBottom = '20px';

    const label = document.createElement('div');
    label.style.fontWeight = 'bold';
    label.style.marginBottom = '4px';
    label.style.color = role === 'User' ? '#58a6ff' : '#2ea043';
    label.textContent = role;

    const content = document.createElement('div');
    content.textContent = text;

    msgDiv.appendChild(label);
    msgDiv.appendChild(content);

    outputContainer.appendChild(msgDiv);
    outputContainer.scrollTop = outputContainer.scrollHeight;

    return content;
  }

  sendBtn.addEventListener('click', generate);

  promptInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      generate();
    }
  });
});
