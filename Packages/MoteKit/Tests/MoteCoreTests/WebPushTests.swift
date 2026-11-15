import Foundation
import Testing

@testable import MoteCore

@Suite("WebPush")
struct WebPushTests {
    @Test("A message encrypted to a subscription's keys reads back as it was sent")
    func roundTrip() throws {
        let keys = WebPush.Keys.make()
        let words = Data(#"{"data":{"title":"Claude","body":"Your task is done"}}"#.utf8)
        let body = try WebPush.encrypt(words, to: keys.publicKey, auth: keys.auth)
        #expect(try WebPush.decrypt(body, with: keys) == words)
    }

    @Test("Another subscription's keys can't read it")
    func wrongKeys() throws {
        let body = try WebPush.encrypt(Data("hello".utf8), to: WebPush.Keys.make().publicKey, auth: WebPush.Keys.make().auth)
        #expect(throws: WebPush.Failure.record) { try WebPush.decrypt(body, with: WebPush.Keys.make()) }
    }

    @Test("The standard's own example decrypts (RFC 8291, appendix A)")
    func standardExample() throws {
        let keys = WebPush.Keys(
            privateKey: try #require(WebPush.data(base64url: "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94")),
            auth: try #require(WebPush.data(base64url: "BTBZMqHH6r4Tts7J_aSIgg")))
        #expect(
            WebPush.base64url(keys.publicKey)
                == "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")
        let body = try #require(
            WebPush.data(
                base64url:
                    "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
            ))
        #expect(String(decoding: try WebPush.decrypt(body, with: keys), as: UTF8.self) == "When I grow up, I want to be a watermelon")
    }

    /// Firefox's own tests of its push decryption (dom/push/test/xpcshell/test_crypto.js): four
    /// messages it reads, records of several sizes and padding among them, and four it refuses.
    struct Vector: CustomTestStringConvertible, Sendable {
        let desc: String, data: String, auth: String, key: String, publicKey: String, result: String?
        init(_ desc: String, data: String, auth: String, key: String, publicKey: String, result: String?) {
            (self.desc, self.data, self.auth, self.key, self.publicKey, self.result) = (desc, data, auth, key, publicKey, result)
        }
        var testDescription: String { desc }
    }

    static let firefox: [Vector] = [
        Vector(
            "Example from draft-ietf-webpush-encryption-latest",
            data:
                "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
            auth: "BTBZMqHH6r4Tts7J_aSIgg", key: "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94",
            publicKey: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
            result: "When I grow up, I want to be a watermelon"),
        Vector(
            "rs = 24, pad = 0",
            data:
                "goagSH7PP0ZGwUsgShmdkwAAABhBBDJVyIuUJbOSVMeWHP8VNPnxY-dZSw86doqOkEzZZZY1ALBWVXTVf0rUDH3oi68I9Hrp-01zA-mr8XKWl5kcH8cX0KiV2PtCwdkEyaQ73YF5fsDxgoWDiaTA3wPqMvuLDqGsZWHnE9Psnfoy7UMEqKlh2a1nE7ZOXiXcOBHLNj260jYzSJnEPV2eXixSXfyWpaSJHAwfj4wVdAAocmViIg6ywk8wFB1hgJpnX2UVEU_qIOcaP6AOIOr1UUQPfosQqC2MEHe5u9gHXF5pi-E267LAlkoYefq01KV_xK_vjbxpw8GAYfSjQEm0L8FG-CN37c8pnQ2Yf61MkihaXac9OctfNeWq_22cN6hn4qsOq0F7QoWIiZqWhB1vS9cJ3KUlyPQvKI9cvevDxw0fJHWeTFzhuwT9BjdILjjb2Vkqc0-qTDOawqD4c8WXsvdGDQCec5Y1x3UhdQXdjR_mhXypxFM37OZTvKJBr1vPCpRXl-bI6iOd7KScgtMM1x5luKhGzZyz25HyuFyj1ec82A",
            auth: "_tK2LDGoIt6be6agJ_nvGA", key: "bGViEe3PvjjFJg8lcnLsqu71b2yqWGnZN9J2MTed-9s",
            publicKey: "BGrgdBhxdAGdiwKHBZ7zlw0uxHgjKKZ824PrUttRTB61GpbhrW-_xKj3XhhXA-kDZSicKZ0kn0BuVhqzhLOB-Cc",
            result: "I am the very model of a modern Major-General; I've information vegetable, animal, and mineral"),
        Vector(
            "rs = 49, pad = 84; ciphertext length falls on record boundary",
            data:
                "-yiDzsHE_K3W0TcfbqSR4AAAADFBBC1EHuf5_2oDKaZJJ9BST9vnsixvtl4Qq0_cA4-UQgoMo_oo2tNshOyRoWLq4Hj6rSwc7XjegRPhlgKyDolPSXa5c-L89oL6DIzNmvPVv_Ht4W-tWjHOGdOLXh_h94pPrYQrvBAlTCxs3ZaitVKE2XLFPK2MO6yxD19X6w1KQzO2BBAroRfK4pEI-9n2Kai6aWDdAZRbOe03unBsQ0oQ_SvSCU_5JJvNrUUTX1_kX804Bx-LLTlBr9pDmBDXeqyvfOULVDJb9YyVAzN9BzeFoyPfo0M",
            auth: "lfF1cOUI72orKtG09creMw", key: "ZwBKTqgg3u2OSdtelIDmPT6jzOGujhpgYJcT1SfQAe8",
            publicKey: "BAFOjxS5LaB84IO5P5Y2foeyF6R_fvLuk6nTQ6oGPldanzDVnGkMajmz_IFbFQyn3RSWAXQTN7U1B6UfQbFzpyE", result: "Hello, world"),
        Vector(
            "rs = 18, pad = 0",
            data:
                "fK69vCCTjuNAqUbxvU9o8QAAABJBBDfP21Ij2fleqgL27ZQP8i6vBbNiLpSdw86fM15u-bJq6qzKD3QICos2RZLyzMbV7d1DAEtwuRiH0UTZ-pPxbDvH6mj0_VR6lOyoSxbhOKYIAXc",
            auth: "1loE35Xy215gSDn3F9zeeQ", key: "J0M_q4lws8tShLYRg--0YoZWLNKnMw2MrpYJEaVXHQw",
            publicKey: "BFFdQyY1VlI5naJLK-kkHmM7XPFPrwzzpv1gMXuVTAovSEhUgASyewz3SAvIEMa-wDqPt5yOoA_IsF4A-INFY-8", result: "1"),
        Vector(
            "Missing header block", data: "RbdNK2m-mwdN47NaqH58FWEd", auth: "NHG7mEgeAlM785VCvPPbpA",
            key: "G-g_ODMu8JaB-vPzB7H_LhDKt4zHzatoOsDukqw_buE",
            publicKey: "BNupkcohU0Pza90-hXyv3j0Yv1fxg1soM7rUFPCIQWIFGslqCyRJADfQfPUo5OGOEAoaZOt0R0hUS_HiINq6zyw", result: nil),
        Vector(
            "Truncated sender key", data: "3ltpa4fxoVy2revdedb5ngAAABIBALa8GCbDfJ9z3WtIWcK1BRgZUg", auth: "XDHg2W2aE5iZrAlp01n3QA",
            key: "zojo4LMFekdS60yPqTHrYhwwLaWtA7ga9FnPZzVWDK4",
            publicKey: "BKMl2ZCExA3gznIqBCxEjZSjJpFyHKeePPdF54xpiGGUsCzqGSJBdnlanU27sgc68szW-m8KTHxJaFVr5QKjuoE", result: nil),
        Vector(
            "Encrypted with mismatched auth secret",
            data:
                "gRX0mIuMOSp7rLQ8jxrFZQAAABJBBBmUSDxUHpvDmmrwP_cTqndFwoThOKQqJDW3l7IMS2mM9RGLT4VVMXwZDqvr-rdJwWTT9r3r4NRBcZExo1fYiQoTxNvUsW_z3VqD98ka1uBArEJzCn8LPNMkXp-Nb_McdR1BDP0",
            auth: "NVo4zW2b7xWZDi0zCNvWAA", key: "YMdjalF95wOaCsLQ4wZEAHlMeOfgSTmBKaInzuD5qAE",
            publicKey: "BP3QQSioXAWJbX-B_hGL3LiHufPB_0GDrcTIJNEoYHMA6Yay37WmEOWvQ-QIoAcwWE-T49_d_ERzfV8I-y1viRY", result: nil),
        Vector(
            "Early final record",
            data:
                "2-IVUH0a09Lq6r6ubodNjwAAABJBBHvEND80qDSM3E5GL_x8QKpqjGGnOcTEHUUSVQX3Dp_F-e-oaFLdSI3Pjo6iyvt14Hq9XufJ1cA4uv7weVcbC9opRBHOmMdt0DHA5YBXekmAo3XkXtMEKb4OLunafm34aW0BuOw",
            auth: "QMJB_eQmnuHm1yVZLZgnGA", key: "XdodkYvEB7o82hLLgBTUmqfgJpACggMERmvIADTKkkA",
            publicKey: "BMlcZSDa0R6Pahv4AxpAwqTuEEXBkDvgah36f4KczrLeAkga5r0EdhIbEsVTLQsjF4gHfvoGg6W_4NYjObJRyzU", result: nil),
    ]

    @Test("Reads what Firefox reads, and refuses what it refuses", arguments: firefox)
    func firefoxVectors(_ vector: Vector) throws {
        let keys = WebPush.Keys(
            privateKey: try #require(WebPush.data(base64url: vector.key)), auth: try #require(WebPush.data(base64url: vector.auth)))
        #expect(WebPush.base64url(keys.publicKey) == vector.publicKey)
        let body = try #require(WebPush.data(base64url: vector.data))
        if let result = vector.result {
            #expect(String(decoding: try WebPush.decrypt(body, with: keys), as: UTF8.self) == result)
        } else {
            #expect(throws: WebPush.Failure.self) { try WebPush.decrypt(body, with: keys) }
        }
    }

    struct Older: CustomTestStringConvertible, Sendable {
        let desc: String, data: String, auth: String, key: String, publicKey: String, cryptoKey: String, encryption: String, result: String?
        init(
            _ desc: String, data: String, auth: String, key: String, publicKey: String, cryptoKey: String, encryption: String,
            result: String?
        ) {
            (self.desc, self.data, self.auth, self.key, self.publicKey) = (desc, data, auth, key, publicKey)
            (self.cryptoKey, self.encryption, self.result) = (cryptoKey, encryption, result)
        }
        var testDescription: String { desc }
    }

    /// Firefox's tests of the older scheme (aesgcm), from the same file.
    static let firefoxOlder: [Older] = [
        Older(
            "padSize = 2, rs = 24, pad = 0", data: "Oo34w2F9VVnTMFfKtdx48AZWQ9Li9M6DauWJVgXU", auth: "aTDc6JebzR6eScy2oLo4RQ",
            key: "4h23G_KkXC9TvBSK2v0Q7ImpS2YAuRd8hQyN0rFAwBg",
            publicKey: "BLHfOWQmxBunRJBjApg8hgSLeOeEMvmKPtcYW2k9iZZOvr3cKpQ-Sp1kpZ9HipNjUCwSA55yy0uM8N9byE8dmLs",
            cryptoKey: "dh=BCHFVrflyxibGLlgztLwKelsRZp4gqX3tNfAKFaxAcBhpvYeN1yIUMrxaDKiLh4LNKPtj0BOXGdr-IQ-QP82Wjo",
            encryption: "salt=zCU18Rw3A5aB_Xi-vfixmA; rs=24", result: "Some message"),
        Older(
            "padSize = 2, rs = 8, pad = 16",
            data:
                "uEC5B_tR-fuQ3delQcrzrDCp40W6ipMZjGZ78USDJ5sMj-6bAOVG3AK6JqFl9E6AoWiBYYvMZfwThVxmDnw6RHtVeLKFM5DWgl1EwkOohwH2EhiDD0gM3io-d79WKzOPZE9rDWUSv64JstImSfX_ADQfABrvbZkeaWxh53EG59QMOElFJqHue4dMURpsMXg",
            auth: "6plwZnSpVUbF7APDXus3UQ", key: "4h23G_KkXC9TvBSK2v0Q7ImpS2YAuRd8hQyN0rFAwBg",
            publicKey: "BLHfOWQmxBunRJBjApg8hgSLeOeEMvmKPtcYW2k9iZZOvr3cKpQ-Sp1kpZ9HipNjUCwSA55yy0uM8N9byE8dmLs",
            cryptoKey: "dh=BEaA4gzA3i0JDuirGhiLgymS4hfFX7TNTdEhSk_HBlLpkjgCpjPL5c-GL9uBGIfa_fhGNKKFhXz1k9Kyens2ZpQ",
            encryption: "salt=ZFhzj0S-n29g9P2p4-I7tA; rs=8", result: "Yet another message"),
        Older(
            "padSize = 2, rs = 3, pad = 0",
            data:
                "oY4e5eDatDVt2fpQylxbPJM-3vrfhDasfPc8Q1PWt4tPfMVbz_sDNL_cvr0DXXkdFzS1lxsJsj550USx4MMl01ihjImXCjrw9R5xFgFrCAqJD3GwXA1vzS4T5yvGVbUp3SndMDdT1OCcEofTn7VC6xZ-zP8rzSQfDCBBxmPU7OISzr8Z4HyzFCGJeBfqiZ7yUfNlKF1x5UaZ4X6iU_TXx5KlQy_toV1dXZ2eEAMHJUcSdArvB6zRpFdEIxdcHcJyo1BIYgAYTDdAIy__IJVCPY_b2CE5W_6ohlYKB7xDyH8giNuWWXAgBozUfScLUVjPC38yJTpAUi6w6pXgXUWffende5FreQpnMFL1L4G-38wsI_-ISIOzdO8QIrXHxmtc1S5xzYu8bMqSgCinvCEwdeGFCmighRjj8t1zRWo0D14rHbQLPR_b1P5SvEeJTtS9Nm3iibM",
            auth: "g2rWVHUCpUxgcL9Tz7vyeQ", key: "4h23G_KkXC9TvBSK2v0Q7ImpS2YAuRd8hQyN0rFAwBg",
            publicKey: "BLHfOWQmxBunRJBjApg8hgSLeOeEMvmKPtcYW2k9iZZOvr3cKpQ-Sp1kpZ9HipNjUCwSA55yy0uM8N9byE8dmLs",
            cryptoKey: "dh=BCg6ZIGuE2ZNm2ti6Arf4CDVD_8--aLXAGLYhpghwjl1xxVjTLLpb7zihuEOGGbyt8Qj0_fYHBP4ObxwJNl56bk",
            encryption: "salt=5LIDBXbvkBvvb7ZdD-T4PQ; rs=3", result: "Small record size"),
        Older(
            "Example from draft-ietf-httpbis-encryption-encoding-02", data: "6nqAQUME8hNqw5J3kl8cpVVJylXKYqZOeseZG8UueKpA",
            auth: "R29vIGdvbyBnJyBqb29iIQ", key: "9FWl15_QUQAWDaD3k3l50ZBZQJ4au27F1V4F0uLSD_M",
            publicKey: "BCEkBjzL8Z3C-oi2Q7oE5t2Np-p7osjGLg93qUP0wvqRT21EEWyf0cQDQcakQMqz4hQKYOQ3il2nNZct4HgAUQU",
            cryptoKey: "keyid=\"dhkey\"; dh=\"BNoRDbb84JGm8g5Z5CFxurSqsXWJ11ItfXEWYVLE85Y7CYkDjXsIEc4aqxYaQ1G8BqkXCJ6DPpDrWtdWj_mugHU\"",
            encryption: "keyid=\"dhkey\"; salt=\"lngarbyKfMoi9Z75xYXmkg\"", result: "I am the walrus"),
        Older(
            "aesgcm128 message decrypted as aesgcm", data: "fwkuwTTChcLnrzsbDI78Y2EoQzfnbMI8Ax9Z27_rwX8", auth: "BhbpNTWyO5wVJmVKTV6XaA",
            key: "4h23G_KkXC9TvBSK2v0Q7ImpS2YAuRd8hQyN0rFAwBg",
            publicKey: "BLHfOWQmxBunRJBjApg8hgSLeOeEMvmKPtcYW2k9iZZOvr3cKpQ-Sp1kpZ9HipNjUCwSA55yy0uM8N9byE8dmLs",
            cryptoKey: "dh=BCHn-I-J3dfPRLJBlNZ3xFoAqaBLZ6qdhpaz9W7Q00JW1oD-hTxyEECn6KYJNK8AxKUyIDwn6Icx_PYWJiEYjQ0",
            encryption: "salt=c6JQl9eJ0VvwrUVCQDxY7Q", result: nil),
        Older(
            "rs = 7, no trailing block", data: "YG4F-b06y590hRlnSsw_vuOw62V9Iz8", auth: "QoDi0u6vcslIVJKiouXMXw",
            key: "2bu4paOAZbL2ef1u-wTzONuTIcDPc00o0zUJgg46XTc",
            publicKey: "BLhLy2VDFZ9ZstHMJy3XBU9Jo9YElObsyNx3hsFwu41_SfNVLGL-FurydsuzciDfw8K1cUHyoDWnJJ_16UG6Dbo",
            cryptoKey: "dh=BD_bsTUpxBMvSv8eksith3vijMLj44D4jhJjO51y7wK1ytbUlsyYBBYYyB5AAe5bnREA_WipTgemDVz00LiWcfM",
            encryption: "salt=xKWvs_jWWeg4KOsot_uBhA; rs=7", result: nil),
        Older(
            "Pad size > last block length", data: "JvX9HsJ4lL5gzP8_uCKc6s15iRIaNhD4pFCgq5-dfwbUqEcNUkqv", auth: "QtGZeY8MQfCaq-XwKOVGBQ",
            key: "CosERAVXgvTvoh7UkrRC2V-iXoNs0bXle9I68qzkles",
            publicKey: "BPw9GKhMIq70yUCXYxusV647LTFaXgM39ttXFKmc-oYG9MnFbM7U14uiYMDI5e2I4jN29tYmsM9F66QodhKmA-c",
            cryptoKey: "dh=BBNZNEi5Ew_ID5S4Y9jWBi1NeVDje6Mjs7SDLViUn6A8VAZj-6X3QAuYQ3j20BblqjwTgYst7PRnY6UGrKyLbmU",
            encryption: "salt=ot8hzbwOo6CYe6ZhdlwKtg; rs=6", result: nil),
        Older(
            "Padding length > last block length", data: "oWSOFA-UO5oWq-kI79RHaFfwAejLiQJ4C7eTmrSTBl4gArLXfx7lZ-Y",
            auth: "gKG_P6-de5pyzS8hyH_NyQ", key: "9l-ahcBM-I0ykwbWiDS9KRrPdhyvTZ0SxKiPpj2aeaI",
            publicKey: "BKsdLVOBA2kL-mshQN8byywXTJp-Ji8Y5-0iupiHiMXoymbMcmUOEyh_-rLrBsi26NG4UFCis2MTDs5FG2VdDPI",
            cryptoKey: "dh=BKe2IBO_cwmEzQyTVscSbQcj0Y3uBSzGZ_mHlANMciS8uGpb7U8_Bw7TNdlYfpwWDLd0cxM8YYWNDbNJ_p2Rp4o",
            encryption: "salt=z7QJ6UR89SiFRkd4RsC4Vg; rs=6", result: nil),
        Older(
            "Non-zero padding", data: "Qdvjh0LkZXKu_1Hvv56D0rOSF6Mww3y0F8xkxUNlwVu2U1iakOUUGRs", auth: "cMpWQW58BrpDbJ8KqbS9ig",
            key: "IzuaxLqFJmjSu8GjLCo2oEaDZjDButW4m4T0qx02XsM",
            publicKey: "BF8u77f0yU8p8cFrEMmNOvQXCpq4ZEY4Sjxbk4vgKYaG0M10IVM1ourR7Q5AUX2b2fgdmGyTWcYsdHcdFK_b4Hk",
            cryptoKey: "dh=BBicj01QI0ryiFzAaty9VpW_crgq9XbU1bOCtEZI9UNE6tuOgp4lyN_UN0N905ECnLWK5v_sCPUIxnQgOuCseSo",
            encryption: "salt=SbkGHONbQBBsBcj9dLyIUw; rs=6", result: nil),
        Older(
            "rs = 6, second record truncated to only auth tag", data: "C7u3j5AL4Yzh2yYB_umN6tzrVHxrt7D5baTEW9DE1Bk3up9fY4w",
            auth: "3rWhsRCU_KdaqfKPbd3zBQ", key: "nhOT9171xuoQBJGkiZ3aqT5qw_ILJ94_PPiVNu1LFSY",
            publicKey: "BJQo-3LUE5kX8M0zHDg5TXx4xTAB5oHSOODoU0F1_8aRWBdgz4GWGtGAisC63O9DtP5l--hnCzPZiV-YZ-a6Lcw",
            cryptoKey: "dh=BI38Qs_OhDmQIxbszc6Nako-MrX3FzAE_8HzxM1wgoEIG4ocxyF-YAAVhfkpJUvDpRyKW2LDHIaoylaZuxQfRhE",
            encryption: "salt=QClh48OlvGpSjZ0Mg0e8rg; rs=6", result: nil),
    ]

    @Test("Reads the older scheme as Firefox does, and refuses what it refuses", arguments: firefoxOlder)
    func firefoxOlderVectors(_ vector: Older) throws {
        let keys = WebPush.Keys(
            privateKey: try #require(WebPush.data(base64url: vector.key)), auth: try #require(WebPush.data(base64url: vector.auth)))
        #expect(WebPush.base64url(keys.publicKey) == vector.publicKey)
        let body = try #require(WebPush.data(base64url: vector.data))
        let read = { try WebPush.decrypt(aesgcm: body, encryption: vector.encryption, cryptoKey: vector.cryptoKey, with: keys) }
        if let result = vector.result {
            #expect(String(decoding: try read(), as: UTF8.self) == result)
        } else {
            #expect(throws: WebPush.Failure.self) { try read() }
        }
    }
}
