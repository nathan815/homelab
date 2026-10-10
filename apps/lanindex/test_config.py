from main import parse_config


def test_parse_config():
    config = {
        "services": [
            {
                "name": "service1",
                "url": "http://service1.$domain",
            },
            {
                "name": "service2",
                "url": "http://service2.$domain",
            },
        ],
        "url_replacements": {"$domain": "lan.nathancj.com"},
        "display_url_replacements": {"$domain": "lan", "http://": ""},
    }
    result = parse_config(config)
    assert len(result.services) == 2

    assert result.services[0].name == "service1"
    assert result.services[0].url == "http://service1.lan.nathancj.com"
    assert result.services[0].display_url == "service1.lan"

    assert result.services[1].name == "service2"
    assert result.services[1].url == "http://service2.lan.nathancj.com"
    assert result.services[1].display_url == "service2.lan"
