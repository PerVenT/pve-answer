import pathlib

import pytest

import server


class StubRequest:
    """Minimal stand-in for web.Request; is_authorized only reads headers."""

    def __init__(self, headers=None):
        self.headers = headers or {}
        self.remote = "10.0.0.1"


# --- normalize_mac ---------------------------------------------------------


@pytest.mark.parametrize(
    "mac",
    [
        "bc:24:11:7b:51:aa",
        "bc-24-11-7b-51-aa",
        "BC24117B51AA",
        "Bc:24:11:7B:51:aA",
    ],
)
def test_normalize_mac_accepts_every_separator_style(mac):
    assert server.normalize_mac(mac) == "bc24117b51aa"


# --- lookup_answer_for_mac -------------------------------------------------


@pytest.fixture
def answers_dir(tmp_path, monkeypatch):
    directory = tmp_path / "answers"
    directory.mkdir()
    (directory / "bc-24-11-7b-51-aa.toml").write_text(
        '[global]\nfqdn = "matched.example.com"\n'
    )
    monkeypatch.setattr(server, "ANSWER_FILE_DIR", directory)
    return directory


def test_lookup_returns_document_and_filename_for_known_mac(answers_dir):
    found = server.lookup_answer_for_mac("BC:24:11:7B:51:AA")

    assert found is not None

    document, name = found

    assert name == "bc-24-11-7b-51-aa"
    assert document["global"]["fqdn"] == "matched.example.com"


def test_lookup_returns_none_for_unknown_mac(answers_dir):
    assert server.lookup_answer_for_mac("00:11:22:33:44:55") is None


# --- create_answer ---------------------------------------------------------


@pytest.fixture
def default_answer(tmp_path, monkeypatch):
    path = tmp_path / "default.toml"
    path.write_text("# no settings, so nothing is installed\n")
    monkeypatch.setattr(server, "DEFAULT_ANSWER_FILE_PATH", path)
    return path


def test_create_answer_reports_the_file_that_matched(answers_dir, default_answer):
    answer, matched = server.create_answer(
        {"network_interfaces": [{"mac": "bc:24:11:7b:51:aa"}]}
    )

    assert matched == "bc-24-11-7b-51-aa"
    assert "matched.example.com" in answer


def test_create_answer_falls_back_to_the_default(answers_dir, default_answer):
    answer, matched = server.create_answer(
        {"network_interfaces": [{"mac": "00:11:22:33:44:55"}]}
    )

    assert matched is None
    assert "nothing is installed" in answer


def test_create_answer_handles_nics_without_a_mac(answers_dir, default_answer):
    answer, matched = server.create_answer(
        {"network_interfaces": [{"name": "eth0"}]}
    )

    assert matched is None


def test_create_answer_handles_a_request_with_no_interfaces(
    answers_dir, default_answer
):
    answer, matched = server.create_answer({})

    assert matched is None


# --- is_authorized ---------------------------------------------------------


def test_is_authorized_allows_everything_when_no_token_is_configured(monkeypatch):
    monkeypatch.setattr(server, "AUTH_TOKEN", None)

    assert server.is_authorized(StubRequest()) is True


@pytest.fixture
def configured_token(monkeypatch):
    token = "provisioning:s3cret"
    monkeypatch.setattr(server, "AUTH_TOKEN", token)
    return token


def test_is_authorized_accepts_the_configured_token(configured_token):
    request = StubRequest({"Authorization": f"Bearer {configured_token}"})

    assert server.is_authorized(request) is True


@pytest.mark.parametrize(
    "header",
    [
        None,
        "",
        "Bearer provisioning:wrong",
        "Bearer ",
        "Basic provisioning:s3cret",
        "provisioning:s3cret",
    ],
    ids=["missing", "empty", "wrong-secret", "no-value", "wrong-scheme", "no-scheme"],
)
def test_is_authorized_rejects_anything_else(configured_token, header):
    headers = {} if header is None else {"Authorization": header}

    assert server.is_authorized(StubRequest(headers)) is False


def test_is_authorized_accepts_a_lowercase_scheme(configured_token):
    request = StubRequest({"Authorization": f"bearer {configured_token}"})

    assert server.is_authorized(request) is True


# --- load_auth_token -------------------------------------------------------


def test_load_auth_token_reads_a_token_file(tmp_path):
    path = tmp_path / "token"
    path.write_text("provisioning:s3cret\n")

    assert server.load_auth_token(path) == "provisioning:s3cret"


def test_load_auth_token_falls_back_to_the_environment(monkeypatch):
    monkeypatch.setenv("PVE_ANSWER_TOKEN", "provisioning:s3cret")

    assert server.load_auth_token(None) == "provisioning:s3cret"


def test_load_auth_token_returns_none_when_nothing_is_configured(monkeypatch):
    monkeypatch.delenv("PVE_ANSWER_TOKEN", raising=False)

    assert server.load_auth_token(None) is None


def test_load_auth_token_rejects_a_token_without_a_name(tmp_path):
    path = tmp_path / "token"
    path.write_text("no-colon-here\n")

    with pytest.raises(RuntimeError, match="<name>:<secret>"):
        server.load_auth_token(path)


def test_load_auth_token_rejects_an_empty_file(tmp_path):
    path = tmp_path / "token"
    path.write_text("   \n")

    with pytest.raises(RuntimeError, match="empty"):
        server.load_auth_token(path)


def test_load_auth_token_rejects_a_missing_file(tmp_path):
    with pytest.raises(RuntimeError, match="does not exist"):
        server.load_auth_token(tmp_path / "absent")


# --- env_flag --------------------------------------------------------------


@pytest.mark.parametrize("value", ["1", "true", "TRUE", "yes", "on", " on "])
def test_env_flag_is_true_for_affirmative_values(monkeypatch, value):
    monkeypatch.setenv("PVE_ANSWER_DEBUG", value)

    assert server.env_flag("PVE_ANSWER_DEBUG") is True


@pytest.mark.parametrize("value", ["0", "false", "no", "off", "", "maybe"])
def test_env_flag_is_false_for_everything_else(monkeypatch, value):
    monkeypatch.setenv("PVE_ANSWER_DEBUG", value)

    assert server.env_flag("PVE_ANSWER_DEBUG") is False


def test_env_flag_is_false_when_unset(monkeypatch):
    monkeypatch.delenv("PVE_ANSWER_DEBUG", raising=False)

    assert server.env_flag("PVE_ANSWER_DEBUG") is False
