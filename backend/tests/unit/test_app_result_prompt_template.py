from pathlib import Path


def test_app_result_prompt_does_not_prefix_template_task_with_literal_dollar():
    source = Path("utils/llm/conversation_processing.py").read_text()

    assert "Task: ${app.memory_prompt}" not in source
    assert "Task: {app.memory_prompt}" in source
