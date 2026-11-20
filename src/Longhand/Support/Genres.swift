import Foundation

/// What the Genre menu offers, by form. Each kind of writing has its own vocabulary: the book
/// trade's for fiction, the film industry's for a screenplay, music's for lyrics, and short
/// lists of kinds for poems, essays and notebooks, which are better named by what they are than
/// by a trade category. The menu is called Genre where the word fits and Type where it doesn't.
/// A genre already set is never changed when the form changes; the menu just keeps showing it.
enum Genres {
    /// BISAC's fiction headings (Book Industry Study Group, the book trade's standard:
    /// bisg.org/fiction, 2025): its 70 headings plus the 18 that it uses only as parents of
    /// sub-headings (Fantasy, Romance, Thrillers …).
    static let book: [String] = [
        "Absurdist", "Action & Adventure", "Adaptations & Pastiche", "African American & Black",
        "Alternative History", "Amish & Mennonite", "Animals", "Anthologies (multiple authors)",
        "Asian American & Pacific Islander", "Biographical & Autofiction", "Books, Bookstores & Libraries",
        "Buddhist", "Christian", "Classics", "Coming of Age", "Cozy", "Crime", "Cultural Heritage",
        "Death, Grief, Bereavement", "Disability", "Disaster", "Diversity & Multicultural", "Dystopian",
        "Epistolary (Letters, Diaries, etc.)", "Erotica", "Fairy Tales, Folk Tales, Legends & Mythology",
        "Family Life", "Fantasy", "Feminist", "Friendship", "Ghost", "Gothic", "Hispanic & Latino",
        "Historical", "Holidays", "Horror", "Humorous", "Immigration & Emigration", "Indigenous",
        "Indigenous Peoples of Turtle Island", "Jewish", "Legal", "LGBTQ+", "Literary",
        "LitRPG (Literary Role-Playing Game)", "Magical Realism", "Mashups", "Media Tie-In", "Medical",
        "Middle Eastern & Arab American", "Multiple Timelines", "Muslim", "Mystery & Detective",
        "Native American", "Nature & the Environment", "Neurodiversity", "Noir", "Occult & Supernatural",
        "Own Voices", "Performing Arts", "Places", "Political", "Prejudice, Racism & Colorism", "Psychological",
        "Religious", "Romance", "Sagas", "Satire", "School & Education", "Science Fiction", "Sea Stories",
        "Short Stories (single author)", "Small Town & Rural", "Southern", "Speculative", "Sports",
        "Suburban", "Superheroes", "Surrealism", "Thrillers", "Time Travel", "Travel & Vacation",
        "Urban & Street Lit", "Visionary & Metaphysical", "War & Military", "Westerns", "Women",
        "World Literature",
    ]

    /// The film industry's movie genres (TMDB's public list, themoviedb.org, 2026).
    static let screenplay: [String] = [
        "Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary", "Drama",
        "Family", "Fantasy", "History", "Horror", "Music", "Mystery", "Romance",
        "Science Fiction", "TV Movie", "Thriller", "War", "Western",
    ]

    /// Kinds of poem: how it is written and what it does, not a shelf in a bookshop.
    static let poetry: [String] = [
        "Ballad", "Elegy", "Epic", "Free Verse", "Ghazal", "Haiku", "Light Verse", "Lyric",
        "Narrative", "Ode", "Pantoum", "Prose Poem", "Sestina", "Sonnet", "Spoken Word", "Villanelle",
    ]

    /// Popular music's usual genres, as a streaming service or a publisher of lyrics lists them.
    static let lyrics: [String] = [
        "Afrobeats", "Alternative", "Blues", "Children’s", "Classical & Opera", "Country", "Electronic",
        "Folk", "Gospel & Spiritual", "Hip-Hop & Rap", "Jazz", "Latin", "Metal", "Musical Theatre",
        "Pop", "Punk", "R&B & Soul", "Reggae", "Rock", "Singer-Songwriter", "World",
    ]

    /// The kinds of essay, as a writing course names them.
    static let essay: [String] = [
        "Argumentative", "Cultural Criticism", "Humorous", "Lyric", "Memoir", "Nature",
        "Opinion", "Personal", "Philosophical", "Political", "Profile", "Reflective", "Review",
        "Scholarly", "Science & Technology", "Travel",
    ]

    /// What a notebook is for.
    static let notebook: [String] = [
        "Character Sketches", "Commonplace Book", "Diary", "Dream Journal", "Ideas", "Journal",
        "Letters", "Research", "Story Planning", "Travel Log", "Worldbuilding",
    ]

    /// The list for a form. A story with no form yet, or one with its own list missing, is read
    /// as fiction.
    static func all(for form: BookForm?) -> [String] {
        switch form {
        case .screenplay: return screenplay
        case .poetry: return poetry
        case .lyrics: return lyrics
        case .essay: return essay
        case .notebook: return notebook
        default: return book
        }
    }

    /// What the menu is called: Genre, except where the choices are kinds.
    static func label(for form: BookForm?) -> String {
        switch form {
        case .poetry, .essay, .notebook: return "Type"
        default: return "Genre"
        }
    }

    /// Where a form's list comes from, for the menu's tooltip.
    static func source(for form: BookForm?) -> String {
        switch form {
        case .screenplay: return "The film industry’s standard movie genres"
        case .poetry: return "Kinds of poem"
        case .lyrics: return "Music’s usual genres"
        case .essay: return "Kinds of essay"
        case .notebook: return "What a notebook is for"
        default: return "The book trade’s standard fiction genres"
        }
    }
}
