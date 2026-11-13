part of '../venue_editor_screen.dart';

// ---------------------------------------------------------------------------
// Step 1 — categories (multi-select) + sports for a Sports Club
// ---------------------------------------------------------------------------
class _CategoryStep extends StatelessWidget {
  const _CategoryStep({required this.venue, required this.onChanged});

  final PartnerVenue venue;
  final VoidCallback onChanged;

  static const _sportIcons = {
    'badminton': Icons.sports_tennis_rounded,
    'table_tennis': Icons.sports_tennis_outlined,
    'cricket': Icons.sports_cricket_rounded,
    'football': Icons.sports_soccer_rounded,
    'basketball': Icons.sports_basketball_rounded,
    'tennis': Icons.sports_tennis_rounded,
    'squash': Icons.sports_handball_rounded,
    'skating': Icons.roller_skating_rounded,
    'swimming': Icons.pool_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final sportsClub = venue.categories.contains('sports_club');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _StepIntro('What kind of venue is it?', 'Select all that apply — members filter by these.'),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.25,
          children: venueVisuals.map((e) {
            final v = e.value;
            final selected = venue.categories.contains(e.key);
            return Tap(
              onTap: () {
                selected ? venue.categories.remove(e.key) : venue.categories.add(e.key);
                if (e.key == 'sports_club' && selected) venue.sports.clear();
                onChanged();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: selected ? AppColors.primary : Colors.transparent, width: 3),
                  boxShadow: selected ? AppShadows.glow(AppColors.primary) : AppShadows.soft,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(17),
                  child: Stack(fit: StackFit.expand, children: [
                    Image.asset(v.image, fit: BoxFit.cover),
                    PhotoScrim(strength: selected ? 0.85 : 0.7),
                    Positioned(
                      left: 12,
                      bottom: 12,
                      right: 12,
                      child: Row(children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(color: v.color, borderRadius: BorderRadius.circular(10)),
                          child: Icon(v.icon, color: Colors.white, size: 16),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(v.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                        ),
                      ]),
                    ),
                    Positioned(
                      top: 10,
                      right: 10,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: selected ? AppColors.primary : Colors.black.withValues(alpha: 0.25),
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: selected ? const Icon(Icons.check_rounded, size: 15, color: Colors.white) : null,
                      ),
                    ),
                  ]),
                ),
              ),
            );
          }).toList(),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          alignment: Alignment.topCenter,
          child: !sportsClub
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const SectionTitle('Which sports?', subtitle: 'Pick every sport members can play here'),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final s in sportLabels.entries)
                        FilterChip(
                          avatar: Icon(_sportIcons[s.key], size: 18,
                              color: venue.sports.contains(s.key) ? AppColors.primary : AppColors.text2),
                          showCheckmark: false,
                          label: Text(s.value),
                          selected: venue.sports.contains(s.key),
                          selectedColor: AppColors.primarySoft,
                          side: BorderSide(color: venue.sports.contains(s.key) ? AppColors.primary : AppColors.line),
                          labelStyle: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: venue.sports.contains(s.key) ? AppColors.primary : AppColors.text,
                          ),
                          onSelected: (on) {
                            on ? venue.sports.add(s.key) : venue.sports.remove(s.key);
                            onChanged();
                          },
                        ),
                    ]),
                    if (venue.sports.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: Text('Pick at least one sport',
                            style: TextStyle(color: AppColors.amber, fontWeight: FontWeight.w700, fontSize: 12.5)),
                      ),
                  ]),
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Step 2 — name, description (≥ 40 chars), contact
// ---------------------------------------------------------------------------
class _DetailsStep extends StatefulWidget {
  const _DetailsStep({required this.venue, required this.formKey, required this.onChanged});

  final PartnerVenue venue;
  final GlobalKey<FormState> formKey;
  final VoidCallback onChanged;

  @override
  State<_DetailsStep> createState() => _DetailsStepState();
}

class _DetailsStepState extends State<_DetailsStep> {
  @override
  Widget build(BuildContext context) {
    final venue = widget.venue;
    final descLen = venue.description.trim().length;
    final descOk = descLen >= minDescriptionLength;
    return Form(
      key: widget.formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _StepIntro('Tell members about your venue', 'This appears on your FITKEY listing.'),
          TextFormField(
            initialValue: venue.name,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            maxLength: 160,
            decoration: const InputDecoration(
              labelText: 'Venue name *',
              hintText: 'e.g. Iron Paradise Gym',
              prefixIcon: Icon(Icons.storefront_rounded),
              counterText: '',
            ),
            onChanged: (v) {
              venue.name = v;
              widget.onChanged();
            },
            validator: (v) => (v ?? '').trim().length < 2 ? 'Enter the venue name' : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            initialValue: venue.description,
            maxLines: 6,
            minLines: 4,
            maxLength: 2000,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Description *',
              alignLabelWithHint: true,
              hintText: 'What makes your place special? Equipment, coaches, classes, vibe, parking…',
              counter: const SizedBox.shrink(),
              helperText: descOk
                  ? 'Looks good · $descLen characters'
                  : '$descLen / $minDescriptionLength characters recommended',
              helperStyle: TextStyle(
                color: descOk ? AppColors.green : (descLen == 0 ? AppColors.text3 : AppColors.amber),
                fontWeight: FontWeight.w700,
              ),
            ),
            onChanged: (v) {
              setState(() => venue.description = v);
              widget.onChanged();
            },
            // Optional: a longer description is recommended (counter below), never required.
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: (descLen / minDescriptionLength).clamp(0.0, 1.0),
              minHeight: 4,
              color: descOk ? AppColors.green : AppColors.amber,
              backgroundColor: AppColors.surfaceAlt,
            ),
          ),
          const SizedBox(height: 18),
          TextFormField(
            initialValue: venue.contactPhone,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.next,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+ -]'))],
            decoration: const InputDecoration(
              labelText: 'Front-desk phone',
              hintText: '98765 43210',
              prefixIcon: Icon(Icons.call_outlined),
            ),
            onChanged: (v) {
              venue.contactPhone = v;
              widget.onChanged();
            },
            validator: (v) => (v ?? '').trim().isEmpty || _validPhone(v!) ? null : 'Enter a valid phone number',
          ),
          const SizedBox(height: 14),
          TextFormField(
            initialValue: venue.contactEmail,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.none,
            autofillHints: const [AutofillHints.email],
            inputFormatters: const [NoWhitespaceFormatter()],
            decoration: const InputDecoration(
              labelText: 'Venue email',
              hintText: 'hello@yourgym.com',
              prefixIcon: Icon(Icons.mail_outline_rounded),
            ),
            onChanged: (v) {
              venue.contactEmail = v;
              widget.onChanged();
            },
            validator: (v) => emailValidator(v, required: false),
          ),
        ],
      ),
    );
  }
}
